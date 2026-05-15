# Agent Skill Tool Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add explicit `$skill_name` skill loading and local slash-command discovery to AI/Agent chats without invalidating DeepSeek prefix-cache history.

**Architecture:** Add a focused `src/skill_registry.zig` module for filesystem scanning and deterministic `SKILL.md` snapshots. Extend AI chat message/history records with replayable tool metadata so skill snapshots can be included in future API transcripts while transient progress cards remain UI-only. Wire `skill_info` as a fixed, stable tool schema and route `$skill_name` plus `/skills`/`/commands`/`/reload-skills` through `Session.submit()`.

**Tech Stack:** Zig 0.15.2, existing OpenAI-compatible tool-call bridge in `src/ai_chat.zig`, existing persistent history store in `src/agent_history.zig`, unit tests via `zig build test`, development build via `zig build`.

---

## Ghostty Reference

Ghostty has no AI chat, agent tool loop, skill package system, or slash command model equivalent to this feature. I checked the current Ghostty `src/` tree with `gh api repos/ghostty-org/ghostty/contents/src`; it contains terminal/runtime modules such as `Surface.zig`, `Command.zig`, `config.zig`, `input.zig`, and renderer/PTY code, but no AI/LLM tool transcript layer. This implementation should therefore stay Phantty-specific and preserve Ghostty-aligned terminal paths by keeping all changes outside terminal emulation.

## File Structure

- Create `src/skill_registry.zig`: owns skill root resolution, `SKILL.md` frontmatter parsing, name lookup, deterministic listing, content hashing, and snapshot rendering.
- Modify `src/test_main.zig`: import `skill_registry.zig` tests.
- Modify `src/agent_history.zig`: persist optional replayable tool metadata on message records.
- Modify `src/ai_chat.zig`: carry tool metadata through UI messages, history conversion, request transcript construction, fixed `skill_info` schema, local slash commands, and `$skill_name` submit handling.
- Modify `README.md`: document `$skill_name`, `/skills`, `/commands`, `/reload-skills`, and the default `skills/` layout.

## Task 1: Add Skill Registry Module

**Files:**
- Create: `src/skill_registry.zig`
- Modify: `src/test_main.zig`
- Test: `src/skill_registry.zig`

- [ ] **Step 1: Write failing registry tests**

Add `src/skill_registry.zig` with tests first. Start the file with this code:

```zig
const std = @import("std");

pub const MAX_SKILL_MD_BYTES: usize = 256 * 1024;

pub const SkillMeta = struct {
    name: []u8,
    description: []u8,
    dir_name: []u8,
    rel_dir: []u8,

    pub fn deinit(self: *SkillMeta, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
        allocator.free(self.dir_name);
        allocator.free(self.rel_dir);
        self.* = undefined;
    }
};

pub const Snapshot = struct {
    name: []u8,
    source: []u8,
    hash_hex: [16]u8,
    content: []u8,

    pub fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.source);
        allocator.free(self.content);
        self.* = undefined;
    }
};

pub const LookupError = error{
    SkillNotFound,
    DuplicateSkillName,
    InvalidSkillMarkdown,
    SkillTooLarge,
};

test "skill_registry: parses SKILL frontmatter and lists sorted skills" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("skills/pdf");
    try tmp.dir.writeFile(.{
        .sub_path = "skills/pdf/SKILL.md",
        .data =
            \\---
            \\name: pdf
            \\description: Work with PDF files.
            \\---
            \\
            \\# PDF
            \\
            \\Use this for PDF tasks.
        ,
    });

    var list = try listSkills(std.testing.allocator, tmp.dir, "skills");
    defer freeSkillList(std.testing.allocator, list);

    try std.testing.expectEqual(@as(usize, 1), list.len);
    try std.testing.expectEqualStrings("pdf", list[0].name);
    try std.testing.expectEqualStrings("Work with PDF files.", list[0].description);
    try std.testing.expectEqualStrings("pdf", list[0].dir_name);
}

test "skill_registry: snapshot is deterministic and includes hash" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("skills/pdf");
    try tmp.dir.writeFile(.{
        .sub_path = "skills/pdf/SKILL.md",
        .data =
            \\---
            \\name: pdf
            \\description: PDF skill.
            \\---
            \\
            \\# PDF Body
        ,
    });

    var snapshot = try loadSkillSnapshot(std.testing.allocator, tmp.dir, "skills", "pdf");
    defer snapshot.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("pdf", snapshot.name);
    try std.testing.expectEqualStrings("skills/pdf", snapshot.source);
    try std.testing.expect(std.mem.indexOf(u8, snapshot.content, "# Skill: pdf") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot.content, "hash: ") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot.content, "# PDF Body") != null);
}

test "skill_registry: duplicate names fail deterministically" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("skills/a");
    try tmp.dir.makePath("skills/b");
    try tmp.dir.writeFile(.{ .sub_path = "skills/a/SKILL.md", .data = "---\nname: same\ndescription: A\n---\nA" });
    try tmp.dir.writeFile(.{ .sub_path = "skills/b/SKILL.md", .data = "---\nname: same\ndescription: B\n---\nB" });

    try std.testing.expectError(
        LookupError.DuplicateSkillName,
        loadSkillSnapshot(std.testing.allocator, tmp.dir, "skills", "same"),
    );
}

test "skill_registry: invalid markdown without frontmatter fails" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("skills/bad");
    try tmp.dir.writeFile(.{ .sub_path = "skills/bad/SKILL.md", .data = "# Missing frontmatter" });

    try std.testing.expectError(
        LookupError.InvalidSkillMarkdown,
        loadSkillSnapshot(std.testing.allocator, tmp.dir, "skills", "bad"),
    );
}
```

- [ ] **Step 2: Import the new tests**

Modify `src/test_main.zig` inside the `comptime` block:

```zig
    _ = @import("skill_registry.zig");
```

- [ ] **Step 3: Run tests to verify failure**

Run: `zig build test`

Expected: FAIL with missing declarations such as `listSkills`, `freeSkillList`, and `loadSkillSnapshot`.

- [ ] **Step 4: Implement registry functions**

In `src/skill_registry.zig`, add these public functions and helpers below the tests:

```zig
pub fn listSkills(allocator: std.mem.Allocator, root_dir: std.fs.Dir, skills_rel: []const u8) ![]SkillMeta {
    var skills_dir = root_dir.openDir(skills_rel, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return allocator.alloc(SkillMeta, 0),
        else => return err,
    };
    defer skills_dir.close();

    var metas: std.ArrayListUnmanaged(SkillMeta) = .empty;
    errdefer {
        for (metas.items) |*meta| meta.deinit(allocator);
        metas.deinit(allocator);
    }

    var it = skills_dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .directory) continue;
        const skill_md_rel = try std.fs.path.join(allocator, &.{ skills_rel, entry.name, "SKILL.md" });
        defer allocator.free(skill_md_rel);
        const bytes = root_dir.readFileAlloc(allocator, skill_md_rel, MAX_SKILL_MD_BYTES) catch |err| switch (err) {
            error.FileNotFound => continue,
            error.FileTooBig => return LookupError.SkillTooLarge,
            else => return err,
        };
        defer allocator.free(bytes);

        const parsed = try parseSkillMarkdown(allocator, entry.name, skills_rel, bytes);
        try metas.append(allocator, parsed);
    }

    std.sort.block(SkillMeta, metas.items, {}, struct {
        fn lessThan(_: void, a: SkillMeta, b: SkillMeta) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.lessThan);

    return metas.toOwnedSlice(allocator);
}

pub fn freeSkillList(allocator: std.mem.Allocator, list: []SkillMeta) void {
    for (list) |*meta| meta.deinit(allocator);
    allocator.free(list);
}

pub fn loadSkillSnapshot(
    allocator: std.mem.Allocator,
    root_dir: std.fs.Dir,
    skills_rel: []const u8,
    skill_name: []const u8,
) !Snapshot {
    const skills = try listSkills(allocator, root_dir, skills_rel);
    defer freeSkillList(allocator, skills);

    var found: ?SkillMeta = null;
    var duplicate = false;
    for (skills) |meta| {
        if (std.mem.eql(u8, meta.name, skill_name) or std.mem.eql(u8, meta.dir_name, skill_name)) {
            if (found != null) duplicate = true;
            found = meta;
        }
    }
    if (duplicate) return LookupError.DuplicateSkillName;
    const meta = found orelse return LookupError.SkillNotFound;

    const skill_md_rel = try std.fs.path.join(allocator, &.{ meta.rel_dir, "SKILL.md" });
    defer allocator.free(skill_md_rel);
    const bytes = root_dir.readFileAlloc(allocator, skill_md_rel, MAX_SKILL_MD_BYTES) catch |err| switch (err) {
        error.FileTooBig => return LookupError.SkillTooLarge,
        else => return err,
    };
    defer allocator.free(bytes);
    _ = try parseSkillMarkdown(allocator, meta.dir_name, skills_rel, bytes);

    var hasher = std.hash.Wyhash.init(0);
    hasher.update(bytes);
    const hash = hasher.final();
    var hash_hex: [16]u8 = undefined;
    _ = try std.fmt.bufPrint(&hash_hex, "{x:0>16}", .{hash});

    const rendered = try std.fmt.allocPrint(
        allocator,
        "# Skill: {s}\nsource: {s}\nhash: {s}\n\n{s}",
        .{ meta.name, meta.rel_dir, hash_hex, bytes },
    );
    errdefer allocator.free(rendered);

    return .{
        .name = try allocator.dupe(u8, meta.name),
        .source = try allocator.dupe(u8, meta.rel_dir),
        .hash_hex = hash_hex,
        .content = rendered,
    };
}

fn parseSkillMarkdown(allocator: std.mem.Allocator, dir_name: []const u8, skills_rel: []const u8, bytes: []const u8) !SkillMeta {
    if (!std.mem.startsWith(u8, bytes, "---\n")) return LookupError.InvalidSkillMarkdown;
    const rest = bytes[4..];
    const end = std.mem.indexOf(u8, rest, "\n---\n") orelse return LookupError.InvalidSkillMarkdown;
    const frontmatter = rest[0..end];

    const name = findFrontmatterValue(frontmatter, "name") orelse dir_name;
    const description = findFrontmatterValue(frontmatter, "description") orelse "";
    const rel_dir = try std.fs.path.join(allocator, &.{ skills_rel, dir_name });
    errdefer allocator.free(rel_dir);

    return .{
        .name = try allocator.dupe(u8, name),
        .description = try allocator.dupe(u8, description),
        .dir_name = try allocator.dupe(u8, dir_name),
        .rel_dir = rel_dir,
    };
}

fn findFrontmatterValue(frontmatter: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, frontmatter, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (!std.mem.startsWith(u8, line, key)) continue;
        var rest = line[key.len..];
        rest = std.mem.trimLeft(u8, rest, " \t");
        if (rest.len == 0 or rest[0] != ':') continue;
        return std.mem.trim(u8, rest[1..], " \t\"'");
    }
    return null;
}
```

- [ ] **Step 5: Run tests**

Run: `zig build test`

Expected: PASS for `skill_registry` tests.

- [ ] **Step 6: Commit**

```bash
git add src/skill_registry.zig src/test_main.zig
git commit -m "feat: add agent skill registry"
```

## Task 2: Persist Replayable Tool Message Metadata

**Files:**
- Modify: `src/agent_history.zig`
- Modify: `src/ai_chat.zig`
- Test: `src/agent_history.zig`
- Test: `src/ai_chat.zig`

- [ ] **Step 1: Write failing history tests**

Add this test near the existing agent history JSON round-trip tests in `src/agent_history.zig`:

```zig
test "agent_history: json round trip preserves replayable tool metadata" {
    const allocator = std.testing.allocator;
    var store = Store.init(allocator);
    defer store.deinit();

    try store.upsertRecord(.{
        .session_id = "session-tool",
        .title = "Tool Session",
        .base_url = "https://api.deepseek.com",
        .api_key = "",
        .model = "deepseek-v4-pro",
        .system_prompt = "You are a helpful assistant.",
        .thinking_enabled = true,
        .reasoning_effort = "high",
        .stream = false,
        .agent_enabled = true,
        .created_at = 1,
        .updated_at = 2,
        .messages = &.{
            .{
                .role = .tool,
                .content = "# Skill: pdf",
                .tool_call_id = "skill-preload-pdf",
                .tool_name = "skill_info",
                .replay_to_model = true,
            },
        },
    });

    const json = try store.toJsonString(allocator);
    defer allocator.free(json);

    var parsed = try Store.fromJsonString(allocator, json);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), parsed.records.items.len);
    const message = parsed.records.items[0].messages[0];
    try std.testing.expectEqual(.tool, message.role);
    try std.testing.expectEqualStrings("skill-preload-pdf", message.tool_call_id.?);
    try std.testing.expectEqualStrings("skill_info", message.tool_name.?);
    try std.testing.expect(message.replay_to_model);
}
```

- [ ] **Step 2: Run test to verify failure**

Run: `zig build test`

Expected: FAIL because `MessageRecord` has no `tool_call_id`, `tool_name`, or `replay_to_model`.

- [ ] **Step 3: Extend history message schema**

Modify `src/agent_history.zig`:

```zig
pub const MessageRecord = struct {
    role: MessageRole,
    content: []const u8,
    reasoning: ?[]const u8 = null,
    usage_footer: ?[]const u8 = null,
    tool_call_id: ?[]const u8 = null,
    tool_name: ?[]const u8 = null,
    replay_to_model: bool = false,
};
```

Update `cloneMessage()`:

```zig
const tool_call_id = if (@hasField(@TypeOf(input), "tool_call_id"))
    try dupeOptionalString(allocator, input.tool_call_id)
else
    null;
errdefer if (tool_call_id) |value| allocator.free(value);
const tool_name = if (@hasField(@TypeOf(input), "tool_name"))
    try dupeOptionalString(allocator, input.tool_name)
else
    null;
errdefer if (tool_name) |value| allocator.free(value);

return .{
    .role = input.role,
    .content = content,
    .reasoning = reasoning,
    .usage_footer = usage_footer,
    .tool_call_id = tool_call_id,
    .tool_name = tool_name,
    .replay_to_model = if (@hasField(@TypeOf(input), "replay_to_model")) input.replay_to_model else false,
};
```

Update `freeOwnedMessage()`:

```zig
if (message.tool_call_id) |tool_call_id| allocator.free(tool_call_id);
if (message.tool_name) |tool_name| allocator.free(tool_name);
```

- [ ] **Step 4: Extend AI chat message model**

Modify `src/ai_chat.zig` `Message`:

```zig
tool_call_id: ?[]u8 = null,
tool_name: ?[]u8 = null,
replay_to_model: bool = false,
```

Update all message deinit sites to free `tool_call_id` and `tool_name`:

```zig
if (msg.tool_call_id) |id| self.allocator.free(id);
if (msg.tool_name) |name| self.allocator.free(name);
```

Update `initFromHistoryRecord()` message append:

```zig
.tool_call_id = if (msg.tool_call_id) |id| try allocator.dupe(u8, id) else null,
.tool_name = if (msg.tool_name) |name| try allocator.dupe(u8, name) else null,
.replay_to_model = msg.replay_to_model,
```

Update `toHistoryRecordLocked()` message conversion:

```zig
.tool_call_id = if (msg.tool_call_id) |id| try allocator.dupe(u8, id) else null,
.tool_name = if (msg.tool_name) |name| try allocator.dupe(u8, name) else null,
.replay_to_model = msg.replay_to_model,
```

- [ ] **Step 5: Run tests**

Run: `zig build test`

Expected: PASS for history schema tests and existing AI chat history tests.

- [ ] **Step 6: Commit**

```bash
git add src/agent_history.zig src/ai_chat.zig
git commit -m "feat: persist replayable agent tool metadata"
```

## Task 3: Replay Only Durable Tool Messages in API Requests

**Files:**
- Modify: `src/ai_chat.zig`
- Test: `src/ai_chat.zig`

- [ ] **Step 1: Write failing request JSON replay tests**

Add this test near existing request JSON tests in `src/ai_chat.zig`:

```zig
test "ai chat request json replays durable tool messages and skips progress tools" {
    const allocator = std.testing.allocator;
    const session = try Session.init(
        allocator,
        "Test",
        DEFAULT_BASE_URL,
        "test-key",
        DEFAULT_MODEL,
        DEFAULT_SYSTEM_PROMPT,
        "enabled",
        "high",
        "false",
        "true",
    );
    defer session.deinit();

    session.mutex.lock();
    try session.messages.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "Use the skill."),
    });
    try session.messages.append(allocator, .{
        .role = .tool,
        .content = try allocator.dupe(u8, "# Skill: pdf"),
        .tool_call_id = try allocator.dupe(u8, "skill-preload-pdf"),
        .tool_name = try allocator.dupe(u8, "skill_info"),
        .replay_to_model = true,
    });
    try session.messages.append(allocator, .{
        .role = .tool,
        .content = try allocator.dupe(u8, "running terminal_list {}"),
        .replay_to_model = false,
    });
    const request = try session.buildRequestLocked();
    session.mutex.unlock();
    defer request.deinit();

    const json = try buildRequestJsonForMessages(allocator, request, request.messages, true);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "# Skill: pdf") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"tool_call_id\":\"skill-preload-pdf\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "running terminal_list") == null);
}
```

- [ ] **Step 2: Run test to verify failure**

Run: `zig build test`

Expected: FAIL because `buildRequestLocked()` currently skips every `.tool` UI message.

- [ ] **Step 3: Include replayable tool messages in requests**

Modify `buildRequestLocked()` in `src/ai_chat.zig`.

Replace the visible count loop with:

```zig
var visible_count: usize = 0;
for (self.messages.items) |msg| {
    if (msg.role != .tool or msg.replay_to_model) visible_count += 1;
}
```

Replace the message copy loop guard with:

```zig
if (msg.role == .tool and !msg.replay_to_model) continue;
messages[written] = .{
    .role = msg.role,
    .content = try self.allocator.dupe(u8, msg.content),
    .reasoning = if (msg.reasoning) |reasoning| try self.allocator.dupe(u8, reasoning) else null,
    .tool_call_id = if (msg.tool_call_id) |id| try self.allocator.dupe(u8, id) else null,
};
```

Do not copy `tool_name` into `RequestMessage`; OpenAI-compatible request tool messages need `role`, `content`, and `tool_call_id`.

- [ ] **Step 4: Run tests**

Run: `zig build test`

Expected: PASS for replay test.

- [ ] **Step 5: Commit**

```bash
git add src/ai_chat.zig
git commit -m "feat: replay durable agent tool messages"
```

## Task 4: Add Fixed `skill_info` Tool

**Files:**
- Modify: `src/ai_chat.zig`
- Test: `src/ai_chat.zig`

- [ ] **Step 1: Write failing tool schema and execution tests**

Add this test near the existing tool schema test:

```zig
test "ai chat agent request json includes stable skill_info tool schema" {
    const allocator = std.testing.allocator;
    const session = try Session.init(
        allocator,
        "Test",
        DEFAULT_BASE_URL,
        "test-key",
        DEFAULT_MODEL,
        DEFAULT_SYSTEM_PROMPT,
        "enabled",
        "high",
        "false",
        "true",
    );
    defer session.deinit();

    session.mutex.lock();
    try session.messages.append(allocator, .{ .role = .user, .content = try allocator.dupe(u8, "hello") });
    const request = try session.buildRequestLocked();
    session.mutex.unlock();
    defer request.deinit();

    const json = try buildRequestJson(allocator, request);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"skill_info\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "skill_name") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "pdf") == null);
}
```

- [ ] **Step 2: Run test to verify failure**

Run: `zig build test`

Expected: FAIL because `skill_info` is not in `appendToolSchemas()`.

- [ ] **Step 3: Add stable tool schema**

In `appendToolSchemas()` after `tab_close`, append a comma and this schema:

```zig
try out.append(allocator, ',');
try out.appendSlice(allocator, toolSchema(
    "skill_info",
    "Load a Phantty skill by stable name. Use when the user explicitly names a skill or asks for specialized skill instructions.",
    "{\"skill_name\":{\"type\":\"string\",\"description\":\"Skill name or skill directory name, such as pdf.\"}}",
));
```

The description must not include the dynamic skill list.

- [ ] **Step 4: Add tool execution path**

Import the registry at the top of `src/ai_chat.zig`:

```zig
const skill_registry = @import("skill_registry.zig");
```

Add this branch to `executeToolCall()` before the unknown-tool fallback:

```zig
if (std.mem.eql(u8, call.name, "skill_info")) {
    const args = parseArgs(request.allocator, call.arguments) orelse return request.allocator.dupe(u8, "Invalid tool arguments");
    defer args.deinit();
    const skill_name = jsonStringArg(args.value, "skill_name") orelse return request.allocator.dupe(u8, "Missing skill_name");
    return skillInfoTool(request.allocator, skill_name);
}
```

Add this helper near other tool helpers:

```zig
fn skillInfoTool(allocator: std.mem.Allocator, skill_name: []const u8) ![]u8 {
    var snapshot = skill_registry.loadSkillSnapshot(allocator, std.fs.cwd(), "skills", skill_name) catch |err| switch (err) {
        skill_registry.LookupError.SkillNotFound => return std.fmt.allocPrint(allocator, "Skill not found: {s}", .{skill_name}),
        skill_registry.LookupError.DuplicateSkillName => return std.fmt.allocPrint(allocator, "Duplicate skill name: {s}", .{skill_name}),
        skill_registry.LookupError.InvalidSkillMarkdown => return std.fmt.allocPrint(allocator, "Invalid SKILL.md for skill: {s}", .{skill_name}),
        skill_registry.LookupError.SkillTooLarge => return std.fmt.allocPrint(allocator, "SKILL.md too large for skill: {s}", .{skill_name}),
        else => |e| return std.fmt.allocPrint(allocator, "Failed to load skill {s}: {}", .{ skill_name, e }),
    };
    defer snapshot.deinit(allocator);
    return allocator.dupe(u8, snapshot.content);
}
```

- [ ] **Step 5: Run tests**

Run: `zig build test`

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/ai_chat.zig
git commit -m "feat: add stable skill info tool"
```

## Task 5: Route Slash Commands and `$skill_name` Submit Flow

**Files:**
- Modify: `src/ai_chat.zig`
- Test: `src/ai_chat.zig`

- [ ] **Step 1: Write failing parser tests**

Add parser tests in `src/ai_chat.zig`:

```zig
test "ai chat parses explicit dollar skill invocation" {
    const parsed = parseSkillInvocation("$pdf summarize this file").?;
    try std.testing.expectEqualStrings("pdf", parsed.skill_name);
    try std.testing.expectEqualStrings("summarize this file", parsed.prompt);

    try std.testing.expect(parseSkillInvocation("normal prompt") == null);
    try std.testing.expect(parseSkillInvocation("$ missing") == null);
}

test "ai chat recognizes local slash commands" {
    try std.testing.expect(parseSlashCommand("/skills").? == .skills);
    try std.testing.expect(parseSlashCommand("/commands").? == .commands);
    try std.testing.expect(parseSlashCommand("/reload-skills").? == .reload_skills);
    try std.testing.expect(parseSlashCommand("/unknown").? == .unknown);
    try std.testing.expect(parseSlashCommand("hello") == null);
}
```

- [ ] **Step 2: Run test to verify failure**

Run: `zig build test`

Expected: FAIL because the parser functions and enum do not exist.

- [ ] **Step 3: Add parsing helpers**

Add these definitions near input helpers in `src/ai_chat.zig`:

```zig
const SlashCommand = enum { skills, commands, reload_skills, unknown };

const SkillInvocation = struct {
    skill_name: []const u8,
    prompt: []const u8,
};

fn parseSlashCommand(input: []const u8) ?SlashCommand {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, "/")) return null;
    if (std.mem.eql(u8, trimmed, "/skills")) return .skills;
    if (std.mem.eql(u8, trimmed, "/commands")) return .commands;
    if (std.mem.eql(u8, trimmed, "/reload-skills")) return .reload_skills;
    return .unknown;
}

fn parseSkillInvocation(input: []const u8) ?SkillInvocation {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, "$") or trimmed.len < 2) return null;
    var end: usize = 1;
    while (end < trimmed.len) : (end += 1) {
        const ch = trimmed[end];
        if (!(std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_')) break;
    }
    if (end == 1) return null;
    const rest = std.mem.trim(u8, trimmed[end..], " \t\r\n");
    if (rest.len == 0) return null;
    return .{ .skill_name = trimmed[1..end], .prompt = rest };
}
```

- [ ] **Step 4: Add local slash command rendering helpers**

Add:

```zig
fn slashCommandOutput(allocator: std.mem.Allocator, command: SlashCommand) ![]u8 {
    return switch (command) {
        .commands => allocator.dupe(u8,
            "Available commands:\n/skills - list available skills\n/commands - list slash commands\n/reload-skills - rescan skills for future calls"
        ),
        .reload_skills => allocator.dupe(u8, "Skills will be re-read from disk on the next skill call."),
        .unknown => allocator.dupe(u8, "Unknown command. Use /commands to list commands."),
        .skills => listSkillsForDisplay(allocator),
    };
}

fn listSkillsForDisplay(allocator: std.mem.Allocator) ![]u8 {
    const list = try skill_registry.listSkills(allocator, std.fs.cwd(), "skills");
    defer skill_registry.freeSkillList(allocator, list);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    if (list.len == 0) {
        try out.appendSlice(allocator, "No skills found under ./skills.");
    } else {
        try out.appendSlice(allocator, "Available skills:\n");
        for (list) |meta| {
            try out.writer(allocator).print("- ${s}: {s}\n", .{ meta.name, meta.description });
        }
    }
    return out.toOwnedSlice(allocator);
}
```

- [ ] **Step 5: Route slash commands before normal submit**

In `Session.submit()`, after trimming `prompt_raw` and API key handling is checked, handle slash commands before appending a user message. Use:

```zig
if (parseSlashCommand(prompt_raw)) |command| {
    const output = slashCommandOutput(self.allocator, command) catch {
        self.setStatusLocked("Could not run command");
        self.mutex.unlock();
        return;
    };
    self.input_len = 0;
    self.input_cursor = 0;
    self.input_scroll_row = 0;
    self.input_scroll_follow_cursor = true;
    self.clearSelectionLocked();
    self.messages.append(self.allocator, .{
        .role = .tool,
        .content = output,
        .content_collapsed = false,
        .content_auto_expand = false,
        .replay_to_model = false,
    }) catch {
        self.allocator.free(output);
        self.setStatusLocked("Out of memory");
        self.mutex.unlock();
        return;
    };
    self.setStatusLocked("Ready");
    history_change = null;
    self.mutex.unlock();
    return;
}
```

Do not call `captureHistoryChangeLocked()` for slash output. It is local UI state and should not dirty agent history.

- [ ] **Step 6: Preload `$skill_name` into replayable transcript**

In `Session.submit()`, parse the skill before duplicating the user prompt:

```zig
const invocation = parseSkillInvocation(prompt_raw);
const prompt_for_history = if (invocation) |parsed| parsed.prompt else prompt_raw;
```

Append the user message from `prompt_for_history`.

After appending the user message and before `buildRequestLocked()`, preload the skill:

```zig
if (invocation) |parsed| {
    const skill_content = skillInfoTool(self.allocator, parsed.skill_name) catch {
        self.setStatusLocked("Could not load skill");
        self.mutex.unlock();
        self.notifyHistoryChange(history_change);
        return;
    };
    errdefer self.allocator.free(skill_content);
    const tool_call_id = try std.fmt.allocPrint(self.allocator, "skill-preload-{s}", .{parsed.skill_name});
    errdefer self.allocator.free(tool_call_id);
    try self.messages.append(self.allocator, .{
        .role = .tool,
        .content = skill_content,
        .tool_call_id = tool_call_id,
        .tool_name = try self.allocator.dupe(u8, "skill_info"),
        .replay_to_model = true,
        .content_collapsed = true,
        .content_auto_expand = false,
    });
}
```

If this code is inside a non-error-returning function, replace `try` with explicit `catch` blocks matching the surrounding `submit()` style.

- [ ] **Step 7: Run tests**

Run: `zig build test`

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add src/ai_chat.zig
git commit -m "feat: route agent skill invocations"
```

## Task 6: Document and Verify

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update README**

Add a short section under the AI/Agent documentation area:

```markdown
### Agent skills

Agent chats can load local skills from `./skills/<skill-name>/SKILL.md`.
Use `$skill-name your request` to explicitly load a skill for the next request.
The loaded skill is stored as a replayable tool result in the chat history, so
existing conversations stay reproducible even if the skill file changes later.

Local slash commands:

- `/skills` lists discovered local skills without calling the model.
- `/commands` lists local AI chat commands without calling the model.
- `/reload-skills` confirms that future skill calls will read from disk again.
```

- [ ] **Step 2: Run unit tests**

Run: `zig build test`

Expected: PASS.

- [ ] **Step 3: Run development build**

Run: `zig build`

Expected: PASS and `zig-out/bin/phantty.exe` exists on Windows.

- [ ] **Step 4: Check Windows path compatibility**

Run the repository Windows path check from `AGENTS.md` in PowerShell on Windows. Expected:

```text
windows_name_violations=0
casefold_collisions=0
```

Run symlink check:

```powershell
git ls-files -s | Select-String '^120000'
```

Expected: no new symlink output from this feature.

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "docs: document agent skill commands"
```

---

## Self-Review

- Spec coverage: The plan covers registry scanning, frontmatter parsing, `/skills`, `/commands`, `/reload-skills`, `$skill_name`, stable `skill_info`, durable replayable tool snapshots, and tests.
- Cache stability: Dynamic skill names never enter tool schema or system prompt. Skill content enters the transcript only as a persisted tool result.
- Ghostty alignment: No terminal emulation, rendering, ConPTY, input shortcut, or Ghostty-shared path is modified.
- Known implementation risk: `Session.submit()` is non-error-returning and currently uses explicit `catch` blocks. Task 5 calls this out so implementation does not paste `try` into non-error code.
