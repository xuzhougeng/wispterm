# Skill Center Binary Tools Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend Skill Center so imported local binary tools are managed as skills and exposed as callable AI Agent function tools when enabled.

**Architecture:** Add a focused executable-tool registry under `<config>/tools`, a probing/import layer that produces canonical `SKILL.md`, dynamic AI tool schema emission and dispatch, and Skill Center UI controls for importing and enabling tools. Keep prompt-skill deploy/import behavior unchanged; binary tools are local-only in this version.

**Tech Stack:** Zig 0.15.2, existing Skill Center model/render/input, `std.process.Child`, `std.json`, WispTerm AI request/protocol/tool layers, platform file dialogs, existing test targets `zig build test` and `zig build test-full`.

---

## File Structure

- Create `src/tool_registry.zig`: pure registry model for installed binary tools, manifest JSON, id/function-name sanitization, generated `SKILL.md`, scan helpers, and enabled-tool snapshots.
- Create `src/tool_import.zig`: impure local import helpers for probing binaries, reading sibling `SKILL.md`, staging/copying binaries, hashing, and installing packages.
- Create `src/tool_skill_draft.zig`: prompt construction and one-shot AI request helper for AI-assisted `SKILL.md` generation when no authored docs exist.
- Modify `src/platform/dirs.zig`: add `<config>/tools` path helpers.
- Modify `src/ai_chat_protocol.zig`: append dynamic binary tool schemas after built-ins in all three protocol emitters.
- Modify `src/ai_chat_types.zig`: carry an enabled-tool snapshot in `AgentSettings`.
- Modify `src/ai_chat.zig` and `src/ai_chat_request.zig`: load enabled tools into request settings and expose a one-shot no-tools AI helper for generated `SKILL.md`.
- Modify `src/ai_chat_tools.zig`: dispatch enabled binary tools by direct argv execution with approval.
- Modify `src/skill_center.zig`: extend panel rows and overlays to include executable tool skills.
- Modify `src/renderer/skill_center_renderer.zig`: render kind/enabled metadata.
- Modify `src/AppWindow.zig`: start tool scans/imports, toggle enabled state, wire AI draft generation.
- Modify `src/input.zig`: add Skill Center tool import/toggle keys and dirty UI after consumed mutations.
- Modify `src/i18n.zig`: update Skill Center title/detail/legend/status strings.
- Modify `src/command_center_state.zig`: update Skill Center detail text to include tools.
- Modify `src/test_fast.zig` and `src/test_main.zig`: include new modules in test aggregators.
- Modify `docs/ai.html`, `docs/ai.zh.html`, and `docs/faq.md`: document executable tool skills and import fallback behavior.

---

### Task 1: Tool Registry And Config Paths

**Files:**
- Create: `src/tool_registry.zig`
- Modify: `src/platform/dirs.zig`
- Modify: `src/test_fast.zig`
- Modify: `src/test_main.zig`

- [ ] **Step 1: Write failing path and registry tests**

Add tests to `src/platform/dirs.zig` in `test "platform dirs expose app skill roots"`:

```zig
    const tools = try toolsDirFromEnvForOs(allocator, .linux, env);
    defer allocator.free(tools);
    const expected_tools = try std.fs.path.join(allocator, &.{ "/home/alice", ".config", app_dir_name, "tools" });
    defer allocator.free(expected_tools);
    try std.testing.expectEqualStrings(expected_tools, tools);
```

Create `src/tool_registry.zig` with these tests at the bottom:

```zig
const std = @import("std");

test "tool_registry: sanitizeFunctionName produces model-safe names" {
    try std.testing.expectEqualStrings("agent_docx_review", try sanitizeFunctionName(std.testing.allocator, "agent-docx-review.exe"));
    try std.testing.expectEqualStrings("tool_123abc", try sanitizeFunctionName(std.testing.allocator, "123abc"));
    try std.testing.expectEqualStrings("my_tool", try sanitizeFunctionName(std.testing.allocator, "My Tool"));
}

test "tool_registry: generated skill markdown includes help and argv contract" {
    const a = std.testing.allocator;
    const md = try generateSkillMdFromHelp(a, .{
        .name = "agent_docx_review",
        .description = "Apply tracked-change review scripts to DOCX files",
        .help = "Usage:\n  agent_docx_review review input.docx output.docx --rules rules.json\n",
    });
    defer a.free(md);
    try std.testing.expect(std.mem.indexOf(u8, md, "name: agent_docx_review") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "args` array") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "review input.docx") != null);
}

test "tool_registry: manifest json round trips enabled tool metadata" {
    const a = std.testing.allocator;
    const manifest = ToolManifest{
        .id = "agent_docx_review",
        .function_name = "agent_docx_review",
        .enabled = true,
        .executable = "bin/agent_docx_review.exe",
        .source_path = "C:/Users/alice/Downloads/agent_docx_review.exe",
        .sha256 = "abc123",
        .imported_at_ms = 1781971200000,
        .description = "Apply tracked-change review scripts to DOCX files",
    };
    const json = try manifestToJson(a, manifest);
    defer a.free(json);
    var parsed = try parseManifestJson(a, json);
    defer parsed.deinit(a);
    try std.testing.expectEqualStrings(manifest.id, parsed.id);
    try std.testing.expectEqualStrings(manifest.function_name, parsed.function_name);
    try std.testing.expect(parsed.enabled);
    try std.testing.expectEqualStrings(manifest.executable, parsed.executable);
}

test "tool_registry: enabledToolSchemas skips disabled tools" {
    const a = std.testing.allocator;
    const enabled = InstalledTool{
        .id = try a.dupe(u8, "docx"),
        .function_name = try a.dupe(u8, "docx"),
        .enabled = true,
        .executable_abs = try a.dupe(u8, "/tmp/tools/docx/bin/docx"),
        .skill_md = try a.dupe(u8, "---\nname: docx\n---\nUse for DOCX review."),
        .description = try a.dupe(u8, "DOCX review"),
    };
    defer enabled.deinit(a);
    const disabled = InstalledTool{
        .id = try a.dupe(u8, "off"),
        .function_name = try a.dupe(u8, "off"),
        .enabled = false,
        .executable_abs = try a.dupe(u8, "/tmp/tools/off/bin/off"),
        .skill_md = try a.dupe(u8, "---\nname: off\n---\nOff."),
        .description = try a.dupe(u8, "Off"),
    };
    defer disabled.deinit(a);
    const list = [_]InstalledTool{ enabled, disabled };
    const snapshot = try enabledSnapshot(a, list[0..]);
    defer freeEnabledSnapshot(a, snapshot);
    try std.testing.expectEqual(@as(usize, 1), snapshot.len);
    try std.testing.expectEqualStrings("docx", snapshot[0].function_name);
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
zig build test
```

Expected: FAIL because `toolsDirFromEnvForOs`, `sanitizeFunctionName`, `generateSkillMdFromHelp`, `ToolManifest`, `manifestToJson`, `parseManifestJson`, `InstalledTool`, `enabledSnapshot`, and `freeEnabledSnapshot` do not exist.

- [ ] **Step 3: Add tools directory helpers**

In `src/platform/dirs.zig`, add after `commandsDirFromEnvForOs`:

```zig
pub fn toolsDir(allocator: std.mem.Allocator) ![]const u8 {
    return pathInConfigDir(allocator, "tools");
}

pub fn toolsDirFromEnvForOs(
    allocator: std.mem.Allocator,
    os_tag: std.Target.Os.Tag,
    env: Env,
) ![]const u8 {
    return pathInConfigDirFromEnvForOs(allocator, os_tag, env, "tools");
}
```

- [ ] **Step 4: Implement `src/tool_registry.zig`**

Use this module structure:

```zig
//! Local executable tool registry for Skill Center binary tools.
const std = @import("std");

pub const MAX_SKILL_MD_BYTES: usize = 256 * 1024;
pub const MAX_TOOL_DESCRIPTION_BYTES: usize = 4096;

pub const ToolManifest = struct {
    id: []const u8,
    function_name: []const u8,
    enabled: bool,
    executable: []const u8,
    source_path: []const u8,
    sha256: []const u8,
    imported_at_ms: i64,
    description: []const u8,
};

pub const OwnedManifest = struct {
    id: []u8,
    function_name: []u8,
    enabled: bool,
    executable: []u8,
    source_path: []u8,
    sha256: []u8,
    imported_at_ms: i64,
    description: []u8,

    pub fn deinit(self: *OwnedManifest, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.function_name);
        allocator.free(self.executable);
        allocator.free(self.source_path);
        allocator.free(self.sha256);
        allocator.free(self.description);
        self.* = undefined;
    }
};

pub const InstalledTool = struct {
    id: []u8,
    function_name: []u8,
    enabled: bool,
    executable_abs: []u8,
    skill_md: []u8,
    description: []u8,

    pub fn deinit(self: *const InstalledTool, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.function_name);
        allocator.free(self.executable_abs);
        allocator.free(self.skill_md);
        allocator.free(self.description);
    }
};

pub const GenerateHelpInput = struct {
    name: []const u8,
    description: []const u8,
    help: []const u8,
};
```

Implement these functions:

```zig
pub fn sanitizeFunctionName(allocator: std.mem.Allocator, raw: []const u8) ![]u8
pub fn generateSkillMdFromHelp(allocator: std.mem.Allocator, input: GenerateHelpInput) ![]u8
pub fn generateSkillMdFromAiDraft(allocator: std.mem.Allocator, name: []const u8, evidence: []const u8, draft: []const u8) ![]u8
pub fn manifestToJson(allocator: std.mem.Allocator, manifest: ToolManifest) ![]u8
pub fn parseManifestJson(allocator: std.mem.Allocator, bytes: []const u8) !OwnedManifest
pub fn readInstalledTool(allocator: std.mem.Allocator, tools_root: []const u8, id: []const u8) !?InstalledTool
pub fn scanInstalledTools(allocator: std.mem.Allocator, tools_root: []const u8) ![]InstalledTool
pub fn freeInstalledTools(allocator: std.mem.Allocator, tools: []InstalledTool) void
pub fn enabledSnapshot(allocator: std.mem.Allocator, tools: []const InstalledTool) ![]InstalledTool
pub fn freeEnabledSnapshot(allocator: std.mem.Allocator, tools: []InstalledTool) void
```

Behavior to implement exactly:

- `sanitizeFunctionName` lowercases ASCII letters, maps non-alphanumeric bytes to `_`, trims repeated `_`, strips `.exe`, prefixes `tool_` when the first character is not `[a-z_]`, and returns `"tool"` when the sanitized name is empty.
- `generateSkillMdFromHelp` emits the deterministic markdown from the design spec and must include the `args` invocation note.
- `generateSkillMdFromAiDraft` emits the strict uncertainty template from the design spec, then appends the AI draft under `## Usage Notes`.
- `manifestToJson` uses `std.json.Stringify` or a manual writer with `ai_chat_protocol.appendJsonString` style escaping; no string concatenation without JSON escaping.
- `parseManifestJson` requires `kind == "binary_tool"` when `kind` exists, requires non-empty `id`, `function_name`, and `executable`, and defaults `enabled` to `false` when missing.
- `scanInstalledTools` ignores malformed tool directories instead of failing the whole scan.
- `enabledSnapshot` deep-copies only `enabled == true` rows.

- [ ] **Step 5: Register modules in test aggregators**

Add `_ = @import("tool_registry.zig");` to the import lists in `src/test_fast.zig` and `src/test_main.zig`.

- [ ] **Step 6: Run tests to verify pass**

Run:

```bash
zig build test
```

Expected: PASS for the new registry and dirs tests.

- [ ] **Step 7: Commit**

```bash
git add src/platform/dirs.zig src/tool_registry.zig src/test_fast.zig src/test_main.zig
git commit -m "feat: add binary tool registry"
```

---

### Task 2: Tool Import Probing And Package Installation

**Files:**
- Create: `src/tool_import.zig`
- Modify: `src/test_fast.zig`
- Modify: `src/test_main.zig`

- [ ] **Step 1: Write failing import decision tests**

Create `src/tool_import.zig` with these tests:

```zig
const std = @import("std");
const tool_registry = @import("tool_registry.zig");

test "tool_import: resolveDocs prefers --skill over sibling skill and help" {
    const a = std.testing.allocator;
    const docs = try resolveDocs(a, .{
        .tool_name = "docx",
        .help_output = "help text",
        .skill_output = "---\nname: docx\n---\nAuthor skill.",
        .sibling_skill = "---\nname: docx\n---\nSibling skill.",
        .ai_draft = null,
    });
    defer a.free(docs.skill_md);
    try std.testing.expectEqual(DocSource.skill_flag, docs.source);
    try std.testing.expect(std.mem.indexOf(u8, docs.skill_md, "Author skill") != null);
}

test "tool_import: resolveDocs uses sibling SKILL.md when --skill is unavailable" {
    const a = std.testing.allocator;
    const docs = try resolveDocs(a, .{
        .tool_name = "docx",
        .help_output = "help text",
        .skill_output = "",
        .sibling_skill = "---\nname: docx\n---\nSibling skill.",
        .ai_draft = null,
    });
    defer a.free(docs.skill_md);
    try std.testing.expectEqual(DocSource.sibling_skill, docs.source);
}

test "tool_import: resolveDocs generates deterministic skill from help" {
    const a = std.testing.allocator;
    const docs = try resolveDocs(a, .{
        .tool_name = "docx",
        .help_output = "docx edits files\nUsage: docx review input output",
        .skill_output = "",
        .sibling_skill = null,
        .ai_draft = null,
    });
    defer a.free(docs.skill_md);
    try std.testing.expectEqual(DocSource.generated_from_help, docs.source);
    try std.testing.expect(std.mem.indexOf(u8, docs.skill_md, "Usage: docx review") != null);
}

test "tool_import: resolveDocs accepts AI draft when no authored docs exist" {
    const a = std.testing.allocator;
    const docs = try resolveDocs(a, .{
        .tool_name = "mystery",
        .help_output = "",
        .skill_output = "",
        .sibling_skill = null,
        .ai_draft = "Use cautiously after the user explains what arguments are needed.",
    });
    defer a.free(docs.skill_md);
    try std.testing.expectEqual(DocSource.ai_draft, docs.source);
    try std.testing.expect(std.mem.indexOf(u8, docs.skill_md, "limited metadata") != null);
}

test "tool_import: resolveDocs blocks when no docs and no AI draft exist" {
    try std.testing.expectError(error.MissingToolDocumentation, resolveDocs(std.testing.allocator, .{
        .tool_name = "mystery",
        .help_output = "",
        .skill_output = "",
        .sibling_skill = null,
        .ai_draft = null,
    }));
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
zig build test
```

Expected: FAIL because `resolveDocs`, `DocSource`, and related types do not exist.

- [ ] **Step 3: Implement doc resolution and probe types**

In `src/tool_import.zig`, add:

```zig
pub const PROBE_TIMEOUT_MS: u32 = 3000;
pub const PROBE_OUTPUT_LIMIT: u32 = 64 * 1024;

pub const DocSource = enum {
    skill_flag,
    sibling_skill,
    generated_from_help,
    ai_draft,
};

pub const ResolveDocsInput = struct {
    tool_name: []const u8,
    help_output: []const u8,
    skill_output: []const u8,
    sibling_skill: ?[]const u8,
    ai_draft: ?[]const u8,
};

pub const ResolvedDocs = struct {
    source: DocSource,
    skill_md: []u8,
};

pub fn resolveDocs(allocator: std.mem.Allocator, input: ResolveDocsInput) !ResolvedDocs {
    const skill_trimmed = std.mem.trim(u8, input.skill_output, " \t\r\n");
    if (skill_trimmed.len > 0) {
        return .{ .source = .skill_flag, .skill_md = try allocator.dupe(u8, skill_trimmed) };
    }
    if (input.sibling_skill) |sibling| {
        const trimmed = std.mem.trim(u8, sibling, " \t\r\n");
        if (trimmed.len > 0) {
            return .{ .source = .sibling_skill, .skill_md = try allocator.dupe(u8, trimmed) };
        }
    }
    const help_trimmed = std.mem.trim(u8, input.help_output, " \t\r\n");
    if (help_trimmed.len > 0) {
        return .{
            .source = .generated_from_help,
            .skill_md = try tool_registry.generateSkillMdFromHelp(allocator, .{
                .name = input.tool_name,
                .description = firstUsefulLine(help_trimmed),
                .help = help_trimmed,
            }),
        };
    }
    if (input.ai_draft) |draft| {
        const draft_trimmed = std.mem.trim(u8, draft, " \t\r\n");
        if (draft_trimmed.len > 0) {
            return .{
                .source = .ai_draft,
                .skill_md = try tool_registry.generateSkillMdFromAiDraft(allocator, input.tool_name, "No --help, --skill, or sibling SKILL.md was available.", draft_trimmed),
            };
        }
    }
    return error.MissingToolDocumentation;
}
```

Add `firstUsefulLine` that returns the first non-empty line up to 180 bytes.

- [ ] **Step 4: Add binary probing and installation functions**

Add these public functions to `src/tool_import.zig`:

```zig
pub const ProbeOutput = struct {
    help: []u8,
    skill: []u8,

    pub fn deinit(self: *ProbeOutput, allocator: std.mem.Allocator) void {
        allocator.free(self.help);
        allocator.free(self.skill);
        self.* = undefined;
    }
};

pub fn probeBinary(allocator: std.mem.Allocator, binary_path: []const u8) !ProbeOutput
pub fn readSiblingSkillMd(allocator: std.mem.Allocator, binary_path: []const u8) ?[]u8
pub fn sha256FileHex(allocator: std.mem.Allocator, path: []const u8) ![]u8
pub fn installToolPackage(
    allocator: std.mem.Allocator,
    tools_root: []const u8,
    source_binary_path: []const u8,
    function_name: []const u8,
    skill_md: []const u8,
    enabled: bool,
) ![]u8
```

Implementation requirements:

- `probeBinary` runs `[binary_path, "--help"]` and `[binary_path, "--skill"]` directly through `ai_chat_tools.runArgv`, not shell execution. Treat non-zero exit as empty output for that probe.
- `readSiblingSkillMd` looks for `SKILL.md` in the source binary's parent directory and reads at most `tool_registry.MAX_SKILL_MD_BYTES`.
- `sha256FileHex` streams the file and returns lowercase hex.
- `installToolPackage` stages under `<tools_root>/.staging-<function_name>`, copies the binary into `bin/<basename>`, writes `SKILL.md`, writes `manifest.json`, then renames into `<tools_root>/<function_name>`. If the target exists, return `error.ToolAlreadyExists`.
- On POSIX, preserve executable mode by opening the source and destination with `copyFile` then setting mode when supported. On Windows, copying the `.exe` is sufficient.

- [ ] **Step 5: Register module and run tests**

Add `_ = @import("tool_import.zig");` to `src/test_fast.zig` and `src/test_main.zig`.

Run:

```bash
zig build test
```

Expected: PASS for `tool_import` decision tests.

- [ ] **Step 6: Commit**

```bash
git add src/tool_import.zig src/test_fast.zig src/test_main.zig
git commit -m "feat: add binary tool import helpers"
```

---

### Task 3: Dynamic Tool Schemas

**Files:**
- Modify: `src/ai_chat_protocol.zig`
- Modify: `src/ai_chat_types.zig`
- Modify: `src/ai_chat.zig`
- Modify: `src/ai_chat_request.zig`

- [ ] **Step 1: Write failing protocol tests**

In `src/ai_chat_protocol.zig`, add:

```zig
test "buildRequestJson advertises enabled binary tools" {
    const a = std.testing.allocator;
    const tools = [_]DynamicToolSpec{.{
        .name = "agent_docx_review",
        .description = "Use for DOCX tracked-change review.",
    }};
    const params = RequestParams{
        .model = "m",
        .system_prompt = "s",
        .protocol = .chat_completions,
        .thinking_enabled = false,
        .reasoning_effort = "",
        .stream = false,
        .dynamic_tools = tools[0..],
    };
    const json = try buildRequestJson(a, params, &.{}, true);
    defer a.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"agent_docx_review\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"args\"") != null);
}

test "subagent toolset excludes binary tools" {
    const a = std.testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(a);
    const tools = [_]DynamicToolSpec{.{ .name = "agent_docx_review", .description = "DOCX" }};
    try appendToolSchemas(a, &out, .{ .include_memory = true, .toolset = .subagent, .dynamic_tools = tools[0..] });
    try std.testing.expect(std.mem.indexOf(u8, out.items, "agent_docx_review") == null);
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
zig build test
```

Expected: FAIL because `DynamicToolSpec`, `RequestParams.dynamic_tools`, and `ToolSpecOpts.dynamic_tools` do not exist.

- [ ] **Step 3: Add protocol dynamic tool types and emitters**

In `src/ai_chat_protocol.zig`, add:

```zig
pub const DynamicToolSpec = struct {
    name: []const u8,
    description: []const u8,
};
```

Extend `RequestParams`:

```zig
dynamic_tools: []const DynamicToolSpec = &.{},
```

Extend `ToolSpecOpts`:

```zig
dynamic_tools: []const DynamicToolSpec = &.{},
```

After built-in tools and memory tools in `forEachToolSpec`, append:

```zig
    if (opts.toolset == .full) {
        for (opts.dynamic_tools) |tool| {
            try Filtered.emitTool(ctx, opts, tool.name, tool.description,
                "{\"args\":{\"type\":\"array\",\"items\":{\"type\":\"string\"},\"description\":\"Command-line arguments to pass after the executable name.\"},\"cwd\":{\"type\":\"string\",\"description\":\"Optional working directory. Defaults to the AI Agent working directory.\"},\"timeout_ms\":{\"type\":\"integer\",\"description\":\"Optional timeout. Defaults to ai-agent-command-timeout-ms.\"}}");
        }
    }
```

Pass `params.dynamic_tools` into `appendToolSchemas`, `appendResponseToolSchemas`, and `appendAnthropicTools`.

- [ ] **Step 4: Carry dynamic tools through settings**

In `src/ai_chat_types.zig`, add to `AgentSettings`:

```zig
dynamic_tools: []const ai_chat_protocol.DynamicToolSpec = &.{},
```

Import `ai_chat_protocol` at the top of `src/ai_chat_types.zig` if not already available.

In `src/ai_chat.zig`, update `currentAgentSettings()` to populate `dynamic_tools` from a threadlocal snapshot:

```zig
threadlocal var g_dynamic_tool_specs: []ai_chat_protocol.DynamicToolSpec = &.{};

pub fn setDynamicToolSpecsForTest(specs: []ai_chat_protocol.DynamicToolSpec) void {
    g_dynamic_tool_specs = specs;
}
```

In the non-test production path, add a helper:

```zig
pub fn reloadDynamicToolSpecs(allocator: std.mem.Allocator) void {
    freeDynamicToolSpecs(allocator);
    g_dynamic_tool_specs = tool_registry.loadDynamicToolSpecs(allocator) catch &.{};
}
```

Use `tool_registry` to load enabled tools from `platform_dirs.toolsDir`.

- [ ] **Step 5: Update request params**

In `src/ai_chat.ChatRequest.toParams`, add:

```zig
.dynamic_tools = ai_chat.currentAgentSettings().dynamic_tools,
```

If `currentAgentSettings()` would copy unrelated mutable settings, add a field to `ChatRequest` instead:

```zig
dynamic_tools: []const ai_chat_protocol.DynamicToolSpec = &.{},
```

Then set it when creating requests and pass `.dynamic_tools = self.dynamic_tools`.

- [ ] **Step 6: Run tests**

Run:

```bash
zig build test
```

Expected: PASS for dynamic schema tests and existing protocol tests.

- [ ] **Step 7: Commit**

```bash
git add src/ai_chat_protocol.zig src/ai_chat_types.zig src/ai_chat.zig src/ai_chat_request.zig
git commit -m "feat: advertise enabled binary tools"
```

---

### Task 4: Binary Tool Runtime Dispatch

**Files:**
- Modify: `src/ai_chat_tools.zig`
- Modify: `src/ai_chat_types.zig`
- Modify: `src/tool_registry.zig`

- [ ] **Step 1: Write failing dispatch tests**

In `src/ai_chat_tools.zig`, add tests near the existing `executeToolCall` tests:

```zig
test "executeToolCall dispatches enabled binary tool by argv" {
    const a = std.testing.allocator;
    const tools = [_]types.DynamicBinaryTool{.{
        .function_name = "fake_tool",
        .executable_abs = "/bin/echo",
        .description = "Echo test",
    }};
    var ctx = ToolContext{
        .allocator = a,
        .ctx = undefined,
        .tool_host = null,
        .tool_snapshot = null,
        .settings = .{
            .permission = .full,
            .working_dir = null,
            .dynamic_binary_tools = tools[0..],
        },
        .approve = alwaysApprove,
        .cancelled = neverCancelled,
    };
    const out = try executeToolCall(&ctx, .{
        .id = @constCast("1"),
        .name = @constCast("fake_tool"),
        .arguments = @constCast("{\"args\":[\"hello\",\"world\"]}"),
    });
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "hello world") != null);
}

test "executeToolCall asks before binary tool in auto mode" {
    var asker = FakeApprover{ .allowed = false };
    const tools = [_]types.DynamicBinaryTool{.{ .function_name = "fake_tool", .executable_abs = "/bin/echo", .description = "Echo" }};
    var ctx = ToolContext{
        .allocator = std.testing.allocator,
        .ctx = &asker,
        .settings = .{ .permission = .auto, .dynamic_binary_tools = tools[0..] },
        .tool_host = null,
        .tool_snapshot = null,
        .approve = FakeApprover.approve,
        .cancelled = neverCancelled,
    };
    const out = try executeToolCall(&ctx, .{ .id = @constCast("1"), .name = @constCast("fake_tool"), .arguments = @constCast("{\"args\":[\"hi\"]}") });
    defer std.testing.allocator.free(out);
    try std.testing.expect(asker.called);
    try std.testing.expect(std.mem.indexOf(u8, out, "denied") != null);
}
```

If `/bin/echo` is not portable for Windows tests, guard the first test:

```zig
if (builtin.os.tag == .windows) return error.SkipZigTest;
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
zig build test
```

Expected: FAIL because `DynamicBinaryTool` and binary dispatch do not exist.

- [ ] **Step 3: Add runtime binary tool snapshot type**

In `src/ai_chat_types.zig`, add:

```zig
pub const DynamicBinaryTool = struct {
    function_name: []const u8,
    executable_abs: []const u8,
    description: []const u8,
};
```

Add to `AgentSettings`:

```zig
dynamic_binary_tools: []const DynamicBinaryTool = &.{},
```

Keep `DynamicToolSpec` for protocol schema and `DynamicBinaryTool` for execution. The runtime type includes the executable path; the protocol type must not.

- [ ] **Step 4: Implement binary dispatch branch**

In `src/ai_chat_tools.zig`, before returning `"Unknown tool"`:

```zig
    if (findDynamicBinaryTool(ctx.settings.dynamic_binary_tools, call.name)) |tool| {
        const args = parseArgs(ctx.allocator, call.arguments) orelse return ctx.allocator.dupe(u8, "Invalid tool arguments");
        defer args.deinit();
        const argv_args = try jsonStringArrayArg(ctx.allocator, args.value, "args");
        defer freeStringArray(ctx.allocator, argv_args);
        const cwd = jsonStringArg(args.value, "cwd") orelse ctx.settings.working_dir;
        const timeout_ms = jsonIntArg(args.value, "timeout_ms") orelse ctx.settings.command_timeout_ms;
        return dynamicBinaryTool(ctx, tool, argv_args, cwd, timeout_ms);
    }
```

Add helpers:

```zig
fn findDynamicBinaryTool(tools: []const types.DynamicBinaryTool, name: []const u8) ?types.DynamicBinaryTool
fn jsonStringArrayArg(allocator: std.mem.Allocator, value: std.json.Value, key: []const u8) ![]const []const u8
fn freeStringArray(allocator: std.mem.Allocator, values: []const []const u8) void
fn dynamicBinaryTool(ctx: *ToolContext, tool: types.DynamicBinaryTool, args: []const []const u8, cwd: ?[]const u8, timeout_ms: u32) ![]u8
```

`dynamicBinaryTool` requirements:

- Ask for approval when permission is `.confirm` or `.auto`.
- Skip approval only for `.full`.
- Approval command text must be a readable argv string, for example `fake_tool hello world`.
- Build argv by allocating `args.len + 1`, setting index 0 to `tool.executable_abs`, and copying args after it.
- Call existing `runArgv`.
- Return the same `exit_code/stdout/stderr` shape as `localCommandExecTool`.
- Truncate with `truncateOwned`.

- [ ] **Step 5: Populate runtime snapshots**

In `src/tool_registry.zig`, add:

```zig
pub fn dynamicSpecsFromInstalled(allocator: std.mem.Allocator, tools: []const InstalledTool) ![]ai_chat_protocol.DynamicToolSpec
pub fn dynamicRuntimeFromInstalled(allocator: std.mem.Allocator, tools: []const InstalledTool) ![]ai_chat_types.DynamicBinaryTool
pub fn freeDynamicSpecs(allocator: std.mem.Allocator, specs: []ai_chat_protocol.DynamicToolSpec) void
pub fn freeDynamicRuntime(allocator: std.mem.Allocator, tools: []ai_chat_types.DynamicBinaryTool) void
```

Descriptions for specs come from `InstalledTool.description`, falling back to truncated `skill_md` when empty.

- [ ] **Step 6: Run tests**

Run:

```bash
zig build test
```

Expected: PASS for binary dispatch and all existing tool tests.

- [ ] **Step 7: Commit**

```bash
git add src/ai_chat_tools.zig src/ai_chat_types.zig src/tool_registry.zig
git commit -m "feat: dispatch binary agent tools"
```

---

### Task 5: AI-Assisted `SKILL.md` Draft Fallback

**Files:**
- Create: `src/tool_skill_draft.zig`
- Modify: `src/ai_chat_request.zig`
- Modify: `src/renderer/overlays.zig`
- Modify: `src/test_fast.zig`
- Modify: `src/test_main.zig`

- [ ] **Step 1: Write failing prompt construction tests**

Create `src/tool_skill_draft.zig` with:

```zig
const std = @import("std");

test "tool_skill_draft: prompt tells model not to invent commands" {
    const a = std.testing.allocator;
    const prompt = try buildDraftPrompt(a, .{
        .tool_name = "mystery",
        .filename = "mystery.exe",
        .sha256 = "abc123",
        .file_size = 12345,
        .platform = "windows",
        .version_output = "mystery 0.1.0",
        .user_note = "This may convert DOCX files.",
    });
    defer a.free(prompt);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "do not invent unsupported commands") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "mystery.exe") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "This may convert DOCX files.") != null);
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
zig build test
```

Expected: FAIL because `buildDraftPrompt` and `DraftInput` do not exist.

- [ ] **Step 3: Implement prompt construction**

In `src/tool_skill_draft.zig`, add:

```zig
pub const DraftInput = struct {
    tool_name: []const u8,
    filename: []const u8,
    sha256: []const u8,
    file_size: u64,
    platform: []const u8,
    version_output: []const u8 = "",
    user_note: []const u8 = "",
};

pub fn buildDraftPrompt(allocator: std.mem.Allocator, input: DraftInput) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\Draft a WispTerm SKILL.md for a local executable tool.
        \\
        \\Rules:
        \\- Return only markdown.
        \\- Include YAML frontmatter with name and description.
        \\- Explain that calls use an args array and the executable name is not included in args.
        \\- Do not invent unsupported commands or flags.
        \\- When evidence is weak, explicitly name uncertainty.
        \\- Keep the draft concise enough to be used as a model tool description.
        \\
        \\Evidence:
        \\- tool name: {s}
        \\- filename: {s}
        \\- sha256: {s}
        \\- file size: {d}
        \\- platform: {s}
        \\- version output: {s}
        \\- user note: {s}
        \\
    , .{ input.tool_name, input.filename, input.sha256, input.file_size, input.platform, input.version_output, input.user_note });
}
```

- [ ] **Step 4: Expose one-shot AI request helper**

In `src/ai_chat_request.zig`, add a public helper that reuses existing HTTP and parsing:

```zig
pub const OneShotProfile = struct {
    base_url: []const u8,
    api_key: []const u8,
    model: []const u8,
    protocol: ApiProtocol,
    thinking_enabled: bool,
    reasoning_effort: []const u8,
    max_tokens: u32,
};

pub fn runOneShotPrompt(allocator: std.mem.Allocator, profile: OneShotProfile, system_prompt: []const u8, user_prompt: []const u8) ![]u8
```

Implementation requirements:

- Construct a minimal `ChatRequest` with `agent_enabled = false`, `stream = false`, and one user message.
- Call `runChatRequestForMessages(&request, messages, false)`.
- Return an owned copy of `ApiResult.content`.
- Do not include tools in the request.

- [ ] **Step 5: Export default AI profile snapshot**

In `src/renderer/overlays.zig`, add:

```zig
pub const DefaultAiProfileSnapshot = struct {
    base_url: []u8,
    api_key: []u8,
    model: []u8,
    protocol: ai_chat.ApiProtocol,
    thinking_enabled: bool,
    reasoning_effort: []u8,
    max_tokens: u32,

    pub fn deinit(self: *DefaultAiProfileSnapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.base_url);
        allocator.free(self.api_key);
        allocator.free(self.model);
        allocator.free(self.reasoning_effort);
        self.* = undefined;
    }
};

pub fn defaultAiProfileSnapshot(allocator: std.mem.Allocator) ?DefaultAiProfileSnapshot
```

Use the same default profile resolution and validation as `makeCopilotSessionForDefaultProfile`. Duplicate strings into the caller allocator.

- [ ] **Step 6: Register and run tests**

Add `_ = @import("tool_skill_draft.zig");` to `src/test_fast.zig` and `src/test_main.zig`.

Run:

```bash
zig build test
```

Expected: PASS for prompt construction. The one-shot network helper has no live network test.

- [ ] **Step 7: Commit**

```bash
git add src/tool_skill_draft.zig src/ai_chat_request.zig src/renderer/overlays.zig src/test_fast.zig src/test_main.zig
git commit -m "feat: add binary tool skill draft fallback"
```

---

### Task 6: Skill Center Model For Prompt Skills Plus Tools

**Files:**
- Modify: `src/skill_center.zig`
- Modify: `src/AppWindow.zig`

- [ ] **Step 1: Write failing Skill Center model tests**

In `src/skill_center.zig`, add:

```zig
test "skill_center: setLibrary accepts prompt skills and tool skills" {
    const a = std.testing.allocator;
    var model = PanelModel.init(a);
    defer model.deinit();

    const rows = try a.alloc(LibraryEntry, 2);
    rows[0] = .{ .prompt_skill = .{
        .name = try a.dupe(u8, "review"),
        .rel_path = try a.dupe(u8, "review/SKILL.md"),
        .agg_hash = null,
    } };
    rows[1] = .{ .tool_skill = .{
        .id = try a.dupe(u8, "agent_docx_review"),
        .function_name = try a.dupe(u8, "agent_docx_review"),
        .enabled = true,
        .description = try a.dupe(u8, "DOCX review"),
        .skill_md = try a.dupe(u8, "# agent_docx_review"),
    } };

    model.setEntries(rows);
    try std.testing.expectEqual(@as(usize, 2), model.entryCount());
    try std.testing.expect(model.selectedEntry().? == .prompt_skill);
    model.move(1);
    try std.testing.expect(model.selectedEntry().? == .tool_skill);
}

test "skill_center: toggleTool only changes selected tool row" {
    const a = std.testing.allocator;
    var model = PanelModel.init(a);
    defer model.deinit();
    const rows = try a.alloc(LibraryEntry, 1);
    rows[0] = .{ .tool_skill = .{
        .id = try a.dupe(u8, "tool"),
        .function_name = try a.dupe(u8, "tool"),
        .enabled = false,
        .description = try a.dupe(u8, "Tool"),
        .skill_md = try a.dupe(u8, "# Tool"),
    } };
    model.setEntries(rows);
    try std.testing.expect(model.toggleSelectedTool());
    try std.testing.expect(model.selectedEntry().?.tool_skill.enabled);
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
zig build test
```

Expected: FAIL because `LibraryEntry`, `setEntries`, `entryCount`, `selectedEntry`, and `toggleSelectedTool` do not exist.

- [ ] **Step 3: Extend Skill Center model**

In `src/skill_center.zig`, add:

```zig
pub const ToolSkill = struct {
    id: []u8,
    function_name: []u8,
    enabled: bool,
    description: []u8,
    skill_md: []u8,

    pub fn deinit(self: *ToolSkill, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.function_name);
        allocator.free(self.description);
        allocator.free(self.skill_md);
        self.* = undefined;
    }
};

pub const LibraryEntry = union(enum) {
    prompt_skill: LibrarySkill,
    tool_skill: ToolSkill,

    pub fn deinit(self: *LibraryEntry, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .prompt_skill => |*s| s.deinit(allocator),
            .tool_skill => |*t| t.deinit(allocator),
        }
        self.* = undefined;
    }

    pub fn name(self: LibraryEntry) []const u8 {
        return switch (self) {
            .prompt_skill => |s| s.name,
            .tool_skill => |t| t.function_name,
        };
    }
};
```

Update `PanelModel`:

- Replace `library: ?[]LibrarySkill` with `entries: ?[]LibraryEntry`.
- Keep a compatibility helper `selected()` that returns `?LibrarySkill` only for prompt skills so existing deploy/import code compiles during migration.
- Add `selectedEntry() ?LibraryEntry`.
- Add `entryCount() usize`.
- Add `setEntries([]LibraryEntry)`.
- Add `toggleSelectedTool() bool`.
- Keep `setLibrary([]LibrarySkill)` by converting prompt skills into `LibraryEntry.prompt_skill` so older scan code still works until `AppWindow` is updated.

- [ ] **Step 4: Merge prompt skill scan with installed tools**

In `src/AppWindow.zig`, update `LibraryScanJob.run` or the scan result handling so the Skill Center model receives combined entries:

1. Scan prompt skills exactly as today.
2. Load installed tools from `platform_dirs.toolsDir`.
3. Convert both to `skill_center.LibraryEntry`.
4. Sort by name with prompt skills and tool skills mixed alphabetically.
5. Call `model.setEntries(entries)`.

Do not change deploy/import target behavior yet. Those actions should no-op or show a status message when a tool row is selected.

- [ ] **Step 5: Run tests**

Run:

```bash
zig build test
```

Expected: PASS for Skill Center model tests.

- [ ] **Step 6: Commit**

```bash
git add src/skill_center.zig src/AppWindow.zig
git commit -m "feat: show binary tools in skill center model"
```

---

### Task 7: Skill Center Rendering And Input

**Files:**
- Modify: `src/renderer/skill_center_renderer.zig`
- Modify: `src/AppWindow.zig`
- Modify: `src/input.zig`
- Modify: `src/i18n.zig`
- Modify: `src/command_center_state.zig`

- [ ] **Step 1: Write failing renderer tests**

In `src/renderer/skill_center_renderer.zig`, add:

```zig
test "skill_center_renderer: list item carries kind and enabled marker" {
    const item = ListItem{
        .label = "agent_docx_review",
        .kind = "tool",
        .enabled = "on",
        .marker = "",
    };
    try std.testing.expectEqualStrings("tool", item.kind);
    try std.testing.expectEqualStrings("on", item.enabled);
}
```

In `src/command_center_state.zig`, update the existing Skill Center test to expect the detail includes tools:

```zig
try std.testing.expect(std.mem.indexOf(u8, entry.detail, "tools") != null or std.mem.indexOf(u8, entry.detail, "Tools") != null);
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
zig build test
```

Expected: FAIL because `ListItem.kind` and `ListItem.enabled` do not exist, and the command detail does not mention tools.

- [ ] **Step 3: Render kind/enabled columns**

In `src/renderer/skill_center_renderer.zig`, extend `ListItem`:

```zig
pub const ListItem = struct {
    label: []const u8,
    marker: []const u8,
    marker_color: [3]f32 = .{ 0, 0, 0 },
    kind: []const u8 = "",
    enabled: []const u8 = "",
};
```

In `renderSkillList` and `renderList`, reserve right-side width:

```zig
const meta_w: f32 = 160;
```

Render `kind` and `enabled` before marker:

```zig
if (item.kind.len > 0) {
    _ = draw.renderTextLimited(item.kind, content_x + content_w - PAD_X - meta_w, text_y, muted, 54);
}
if (item.enabled.len > 0) {
    _ = draw.renderTextLimited(item.enabled, content_x + content_w - PAD_X - meta_w + 62, text_y, item.marker_color, 54);
}
```

For the main list, add an accessor callback or replace `nameAt` with `itemAt` so `AppWindow.scEntryItemAt` can provide kind/enabled metadata.

- [ ] **Step 4: Add AppWindow item accessors**

In `src/AppWindow.zig`, replace `scNameAt` usage with an item accessor:

```zig
fn scEntryItemAt(ctx: *anyopaque, i: usize) skill_center_renderer.ListItem {
    const m: *const skill_center.PanelModel = @ptrCast(@alignCast(ctx));
    const entry = m.entryAt(i) orelse return .{ .label = "", .marker = "" };
    return switch (entry) {
        .prompt_skill => |s| .{ .label = s.name, .marker = "", .kind = "skill" },
        .tool_skill => |t| .{
            .label = t.function_name,
            .marker = "",
            .kind = "tool",
            .enabled = if (t.enabled) "on" else "off",
            .marker_color = if (t.enabled) .{ 0.3, 0.85, 0.45 } else .{ 0.85, 0.45, 0.35 },
        },
    };
}
```

- [ ] **Step 5: Add input actions**

In `src/input.zig`, update the Skill Center branch:

- `T` imports a binary tool when no text/selection overlay is active.
- `E` toggles selected tool enabled state when no text/selection overlay is active.
- Existing `D` and `I` deploy/import only prompt skills.

Every consumed key must set:

```zig
AppWindow.g_force_rebuild = true;
AppWindow.g_cells_valid = false;
```

Add or update tests in `src/input.zig` full-test area to verify Skill Center tool toggle dirties the UI.

- [ ] **Step 6: Add AppWindow tool action functions**

In `src/AppWindow.zig`, add:

```zig
pub fn skillCenterImportTool() bool
pub fn skillCenterToggleToolEnabled() bool
```

`skillCenterToggleToolEnabled`:

- Requires selected row is `.tool_skill`.
- Updates `<config>/tools/<id>/manifest.json` enabled value.
- Updates the in-memory row.
- Calls `ai_chat.reloadDynamicToolSpecs(allocator)` after write.
- Calls `markUiDirty()`.

`skillCenterImportTool` starts the import flow added in Task 8. Until Task 8 is implemented, it should set a status string such as `"Tool import unavailable"` and return true so input wiring can be tested.

- [ ] **Step 7: Update strings**

In `src/i18n.zig`, update English and Chinese:

- `sl_skill_center_detail`: include tools.
- `sc_legend_v2`: include `T import tool` and `E enable`.
- Add status strings:
  - `sc_tool_importing`
  - `sc_tool_import_failed`
  - `sc_tool_enabled`
  - `sc_tool_disabled`

In `src/command_center_state.zig`, change Skill Center detail to:

```zig
"Manage Claude Code / Codex skills and local executable tools"
```

- [ ] **Step 8: Run full tests for input path**

Run:

```bash
zig build test
zig build test-full
```

Expected: PASS. `test-full` is required because `input.zig` is not compiled by the fast suite.

- [ ] **Step 9: Commit**

```bash
git add src/renderer/skill_center_renderer.zig src/AppWindow.zig src/input.zig src/i18n.zig src/command_center_state.zig
git commit -m "feat: add skill center tool controls"
```

---

### Task 8: End-To-End Tool Import Flow

**Files:**
- Modify: `src/AppWindow.zig`
- Modify: `src/skill_center.zig`
- Modify: `src/tool_import.zig`
- Modify: `src/platform/file_dialog.zig` only if filter support needs a small helper

- [ ] **Step 1: Write failing import overlay tests**

In `src/skill_center.zig`, add:

```zig
test "skill_center: tool import preview overlay stores staged import" {
    const a = std.testing.allocator;
    var model = PanelModel.init(a);
    defer model.deinit();
    try model.openToolImportPreview(.{
        .tool_id = "agent_docx_review",
        .function_name = "agent_docx_review",
        .source_path = "/tmp/agent_docx_review",
        .staged_binary_path = "/tmp/stage/bin/agent_docx_review",
        .skill_md = "---\nname: agent_docx_review\n---\nDocx.",
        .doc_source = .skill_flag,
        .ai_review_required = false,
    });
    try std.testing.expect(model.overlay == .tool_import_preview);
}
```

- [ ] **Step 2: Run tests to verify failure**

Run:

```bash
zig build test
```

Expected: FAIL because `openToolImportPreview` and `.tool_import_preview` do not exist.

- [ ] **Step 3: Add import overlay state**

In `src/skill_center.zig`, add:

```zig
pub const ToolImportPreviewState = struct {
    tool_id: []u8,
    function_name: []u8,
    source_path: []u8,
    staged_binary_path: []u8,
    skill_md: []u8,
    doc_source: tool_import.DocSource,
    ai_review_required: bool,
    scroll: usize = 0,

    pub fn deinit(self: *ToolImportPreviewState, allocator: std.mem.Allocator) void {
        allocator.free(self.tool_id);
        allocator.free(self.function_name);
        allocator.free(self.source_path);
        allocator.free(self.staged_binary_path);
        allocator.free(self.skill_md);
        self.* = undefined;
    }
};
```

Add `.tool_import_preview: ToolImportPreviewState` to `Overlay`, deinit it, and render it through the existing text preview path with a footer hint:

```text
Enter import · Esc cancel · ↑/↓ scroll
```

- [ ] **Step 4: Implement `skillCenterImportTool` file picker**

In `src/AppWindow.zig`, implement `skillCenterImportTool`:

1. Use `platform_file_dialog.openFile` with title `"Import executable tool"`.
2. Probe selected binary with `tool_import.probeBinary`.
3. Read sibling `SKILL.md`.
4. Resolve docs without AI draft.
5. If docs resolve, open import preview.
6. If `error.MissingToolDocumentation`, call Task 5 AI draft helper:
   - Get `overlays.defaultAiProfileSnapshot`.
   - If unavailable, show status `"Add an AI profile or provide SKILL.md next to the binary."`
   - Build draft prompt from metadata.
   - Run one-shot request on a background op thread.
   - On completion, open import preview with `ai_review_required = true`.

Do not run the network request on the UI thread.

- [ ] **Step 5: Confirm import from overlay**

Update `skillCenterOverlaySelect` in `src/AppWindow.zig`:

- If overlay is `.tool_import_preview`, call `tool_import.installToolPackage`.
- On success, close overlay, rescan Skill Center, call `ai_chat.reloadDynamicToolSpecs`.
- On failure, keep overlay open and set status to the error summary.

Update `skillCenterOverlayCancel` to remove any staging directory for `.tool_import_preview`.

- [ ] **Step 6: Wire AI draft result through existing op worker**

Extend `skill_center.OpResult`:

```zig
tool_import_preview: ToolImportPreviewState,
```

The worker returns this when AI draft generation completes. `pollSkillCenterOp` moves it into `model.overlay`.

- [ ] **Step 7: Run tests**

Run:

```bash
zig build test
zig build test-full
```

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add src/AppWindow.zig src/skill_center.zig src/tool_import.zig
git commit -m "feat: import binary tools from skill center"
```

---

### Task 9: Documentation And Verification

**Files:**
- Modify: `docs/ai.html`
- Modify: `docs/ai.zh.html`
- Modify: `docs/faq.md`
- Modify: `README.md` only if the visible Skill Center shortcut text changes outside the panel legend

- [ ] **Step 1: Update AI docs**

In `docs/ai.html`, under the skills section, add a paragraph:

```html
<p>Skill Center also manages local executable tools. Imported tools are stored under the WispTerm config directory, documented by <code>SKILL.md</code>, and only enabled tools are advertised to AI Agent sessions. A tool can provide <code>--skill</code>, ship a sibling <code>SKILL.md</code>, or let WispTerm draft one with the configured AI profile when no documentation exists.</p>
```

Add the equivalent Chinese paragraph to `docs/ai.zh.html`.

- [ ] **Step 2: Update FAQ**

In `docs/faq.md`, extend the Skill Center answer with:

```markdown
Skill Center also accepts local executable tools. Tools are imported as skills: WispTerm stores the binary, keeps a canonical `SKILL.md`, and exposes enabled tools as AI Agent function tools. If a binary has neither `--skill` nor a packaged `SKILL.md`, WispTerm can draft one from limited metadata with your configured AI profile and asks you to review it before enabling the tool.
```

- [ ] **Step 3: Run verification**

Run:

```bash
zig build test
zig build test-full
```

Expected: PASS.

Because this plan adds new files, run the Windows checkout-safety checks from `docs/development.md#windows-checkout-safety`.

- [ ] **Step 4: Manual smoke test**

Use a local fake executable:

```bash
mkdir -p .zig-cache/tool-smoke
cat > .zig-cache/tool-smoke/fake_tool <<'SH'
#!/bin/sh
if [ "$1" = "--skill" ]; then
  printf '%s\n' '---' 'name: fake_tool' 'description: Fake smoke tool' '---' '' '# fake_tool' '' 'Echoes args.'
  exit 0
fi
if [ "$1" = "--help" ]; then
  echo "fake_tool echoes args"
  exit 0
fi
printf 'args:'
for arg in "$@"; do printf ' [%s]' "$arg"; done
printf '\n'
SH
chmod +x .zig-cache/tool-smoke/fake_tool
```

Open WispTerm, open Skill Center, import `.zig-cache/tool-smoke/fake_tool`, enable it, then ask an Agent tab to call `fake_tool` with `args=["hello"]`. Expected result includes `args: [hello]`.

- [ ] **Step 5: Commit docs**

```bash
git add docs/ai.html docs/ai.zh.html docs/faq.md README.md
git commit -m "docs: document skill center binary tools"
```

---

## Self-Review Checklist

- Spec coverage: local binary tools, `--skill`, sibling `SKILL.md`, optional `--help`, AI-assisted fallback, user review, enable/disable, dynamic schemas, direct argv dispatch, approvals, docs, and tests are each covered by a task.
- Scope guards: no remote binary deploy/import, no marketplace download, no shell execution, no structured schema inference, and no per-tool trust policy are preserved.
- Type consistency: `DynamicToolSpec` is model-facing only; `DynamicBinaryTool` is runtime-facing only; `InstalledTool` belongs to `tool_registry`.
- Event-driven UI rule: Task 7 explicitly updates `input.zig` dirty handling and requires `test-full`.
- Windows safety: Task 9 includes checkout-safety checks because new files are added.
