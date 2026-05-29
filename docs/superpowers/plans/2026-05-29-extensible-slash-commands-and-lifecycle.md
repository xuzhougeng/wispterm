# Extensible Slash Commands + Lifecycle Commands — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add built-in `/clear`, `/resume`, `/permission`, `/export`, `/reload-commands` slash commands and a user-extensible `commands/` directory to the AI Chat panel, all sharing one dispatch path.

**Architecture:** Built-in commands stay a compile-time array + enum in `ai_chat_composer.zig` (just extended). User commands load from a `commands/` directory via a new `command_registry.zig` peer to `skill_registry.zig`. The composer's pure suggestion/parse functions gain an extra `custom: []const SlashCommandSuggestion` parameter (existing callers pass `&.{}`). Cross-layer actions (`/resume` opens the history picker, `/export` writes a file) fire global callbacks set once at startup, mirroring `setSkillUpdateTrigger` (`ai_chat.zig:317`).

**Tech Stack:** Zig; tests run via `zig build test` (native) — see memory `phantty-test-execution-env`. New modules MUST be `_ = @import`ed in `test_fast.zig`/`test_main.zig` to register tests (repo test-inclusion rule).

**Spec:** `docs/superpowers/specs/2026-05-29-extensible-slash-commands-and-lifecycle-design.md`

---

## File Structure

- **Modify** `src/ai_chat_composer.zig` — add new built-in `SlashCommand` enum variants + `slash_command_entries`; add `custom: []const SlashCommandSuggestion` param to slash suggestion/parse functions.
- **Modify** `src/ai_chat.zig` — `slashCommandOutput` for new commands; `Session.clearContext`; custom-command field + loading; dispatch wiring; two new startup callbacks.
- **Create** `src/command_registry.zig` — pure scan/parse of `commands/*.md` → `[]CustomCommand`. Peer to `skill_registry.zig`.
- **Modify** `src/AppWindow.zig` — register `/resume` (open history picker) and `/export` (call `exportActiveAiChatMarkdown`) callbacks at startup, next to the existing `setSkillUpdateTrigger` wiring.
- **Modify** `src/test_fast.zig` (and `src/test_main.zig` if needed) — `_ = @import("command_registry.zig");`.

---

## Task 1: Add built-in lifecycle commands to the enum + entries

**Files:**
- Modify: `src/ai_chat_composer.zig:6` (enum), `:29` (entries array)
- Test: `src/ai_chat_composer.zig` (inline tests)

- [ ] **Step 1: Write the failing test** — append to the existing `parseSlashCommand` test block in `ai_chat_composer.zig`:

```zig
test "parseSlashCommand recognizes new lifecycle commands" {
    try std.testing.expectEqual(SlashCommand.clear, parseSlashCommand("/clear").?);
    try std.testing.expectEqual(SlashCommand.resume_session, parseSlashCommand("/resume").?);
    try std.testing.expectEqual(SlashCommand.permission, parseSlashCommand("/permission").?);
    try std.testing.expectEqual(SlashCommand.export_markdown, parseSlashCommand("/export").?);
    try std.testing.expectEqual(SlashCommand.reload_commands, parseSlashCommand("/reload-commands").?);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | head -40`
Expected: FAIL — `error: no field named 'clear' in enum 'SlashCommand'`.

- [ ] **Step 3: Extend the enum** at `ai_chat_composer.zig:6`:

```zig
pub const SlashCommand = enum {
    skills,
    commands,
    reload_skills,
    update_skills,
    reload_commands,
    clear,
    resume_session,
    permission,
    export_markdown,
    unknown,
};
```

- [ ] **Step 4: Add entries** to `slash_command_entries` (`:29`), after the `update-skills` entry:

```zig
    .{ .suggestion = .{ .command = "/clear", .description = "clear the conversation context" }, .action = .clear },
    .{ .suggestion = .{ .command = "/resume", .description = "resume a saved conversation" }, .action = .resume_session },
    .{ .suggestion = .{ .command = "/permission", .description = "view or set agent permission" }, .action = .permission },
    .{ .suggestion = .{ .command = "/export", .description = "export conversation as Markdown" }, .action = .export_markdown },
    .{ .suggestion = .{ .command = "/reload-commands", .description = "rescan the commands directory" }, .action = .reload_commands },
```

Note: `/permission` and `/export` accept an optional argument (e.g. `/export full`). `parseSlashCommand` (`:64`) currently rejects any input containing a space (`:70`). Leave that as-is for now — argument parsing is handled in Task 6 at the dispatch site by matching the **first token**; the suggestion list still matches the bare command.

- [ ] **Step 5: Run test to verify it passes**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/ai_chat_composer.zig
git commit -m "feat(ai-chat): add lifecycle slash command enum variants and entries"
```

---

## Task 2: Handle new built-in commands in `slashCommandOutput`

**Files:**
- Modify: `src/ai_chat.zig:364` (`slashCommandOutput`)
- Test: `src/ai_chat.zig` (inline)

`slashCommandOutput` produces the transcript text for a command. `/clear`, `/resume`, `/export` mostly act via state/callbacks (Task 6) but still emit a short confirmation line; `/permission` and `/reload-commands` emit informative text.

- [ ] **Step 1: Write the failing test** (append near the existing slash-command tests in `ai_chat.zig`, ~`:4282`):

```zig
test "slashCommandOutput covers new lifecycle commands" {
    const a = std.testing.allocator;
    inline for (.{
        .{ SlashCommand.clear, "Cleared" },
        .{ SlashCommand.reload_commands, "commands" },
        .{ SlashCommand.permission, "permission" },
        .{ SlashCommand.export_markdown, "Export" },
        .{ SlashCommand.resume_session, "history" },
    }) |case| {
        const out = try slashCommandOutput(a, case[0]);
        defer a.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, case[1]) != null);
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | head -40`
Expected: FAIL — switch on `SlashCommand` is not exhaustive / unhandled variants.

- [ ] **Step 3: Extend `slashCommandOutput`** (`:364`):

```zig
fn slashCommandOutput(allocator: std.mem.Allocator, command: SlashCommand) ![]u8 {
    return switch (command) {
        .commands => slashCommandListOutput(allocator),
        .reload_skills => allocator.dupe(u8, "Skills will be re-read from disk on the next skill call."),
        .reload_commands => allocator.dupe(u8, "Custom commands will be re-read from the commands directory."),
        .update_skills => allocator.dupe(u8, "Downloading the latest skills from GitHub in the background..."),
        .clear => allocator.dupe(u8, "Cleared the conversation context."),
        .resume_session => allocator.dupe(u8, "Opening saved conversation history..."),
        .permission => permissionStatusOutput(allocator),
        .export_markdown => allocator.dupe(u8, "Exporting the conversation as Markdown..."),
        .unknown => allocator.dupe(u8, "Unknown command. Use /commands to list commands."),
        .skills => listSkillsForDisplay(allocator),
    };
}

fn permissionStatusOutput(allocator: std.mem.Allocator) ![]u8 {
    const current = currentAgentSettings().permission;
    return std.fmt.allocPrint(allocator, "Agent permission is '{s}'. Use /permission confirm or /permission full to change it.", .{current.name()});
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/ai_chat.zig
git commit -m "feat(ai-chat): slashCommandOutput handles lifecycle commands"
```

---

## Task 3: Reuse `clearMessages` for `/clear` (mutex-held split)

**Files:**
- Modify: `src/ai_chat.zig` (`clearMessages` at `:1545`)
- Test: `src/ai_chat.zig` (inline)

**Do NOT add a new `clearContext`.** `Session.clearMessages` (`:1545`) already does exactly what `/clear` needs — frees messages, resets scroll + `suggestion_selected`, clears selection, sets status, and fires the history-change notification, guarded by `request_inflight`. The problem: it **locks `self.mutex` itself**, but the slash-command dispatch (Task 6) runs with the mutex already held, so calling it there would **deadlock**. So split it into a mutex-held core + a locking wrapper, and have Task 6 call the core.

If a `clearContext` was added in an earlier attempt, **remove it** (it duplicates `clearMessages` and skips the inflight guard / history notification).

- [ ] **Step 1: Write the failing test** (inline). Adapt the `Session.init` call to the REAL signature: `Session.init(allocator, name, base_url, api_key, model_name, system_prompt, thinking, reasoning_effort, stream_val, agent_val)`:

```zig
test "clearMessages empties transcript but keeps settings" {
    const a = std.testing.allocator;
    var session = try Session.init(a, "chat", "https://api.example.com", "key", "m1", "sys", "false", "", "false", "false");
    defer session.deinit();
    try session.messages.append(a, .{ .role = .user, .content = try a.dupe(u8, "hi") });
    try std.testing.expect(session.messages.items.len > 0);

    session.clearMessages();
    try std.testing.expectEqual(@as(usize, 0), session.messages.items.len);
    try std.testing.expectEqualStrings("sys", session.systemPrompt());
    try std.testing.expectEqualStrings("m1", session.model());
}
```

(Match the exact `Message` literal shape used at `ai_chat.zig:1428`; adjust the `init` args to the real signature/accessor names you find.)

- [ ] **Step 2: Run test to verify it fails or passes**

Run: `zig build test 2>&1 | head -40`. (`clearMessages` already exists, so this test may PASS immediately — that's fine; its purpose is to lock in the keep-settings behavior. If it fails, fix the test to the real signatures.)

- [ ] **Step 3: Split `clearMessages` into a mutex-held core + wrapper.** Replace the existing `clearMessages` (`:1545`) with:

```zig
/// Assumes self.mutex is held. Returns the captured history change for the
/// caller to notify after unlocking.
fn clearMessagesLocked(self: *Session) ?PendingHistoryChange {
    for (self.messages.items) |msg| msg.deinit(self.allocator);
    self.messages.clearRetainingCapacity();
    self.scroll_px = 0;
    self.suggestion_selected = 0;
    self.clearSelectionLocked();
    self.setStatusLocked("Cleared");
    return self.captureHistoryChangeLocked();
}

fn clearMessages(self: *Session) void {
    self.mutex.lock();
    if (self.request_inflight) {
        self.mutex.unlock();
        return;
    }
    const history_change = self.clearMessagesLocked();
    self.mutex.unlock();
    self.notifyHistoryChange(history_change);
}
```

This preserves the existing caller at `:1103` (`self.clearMessages()`) unchanged. Task 6 will call `clearMessagesLocked()` from the mutex-held dispatch.

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS (no deadlock, no leak — leak-checking allocator).

- [ ] **Step 5: Commit**

```bash
git add src/ai_chat.zig
git commit -m "refactor(ai-chat): split clearMessages into mutex-held core for /clear reuse"
```

---

## Task 4: `command_registry.zig` — scan `commands/*.md`

**Files:**
- Create: `src/command_registry.zig`
- Modify: `src/test_fast.zig` (add import)
- Test: `src/command_registry.zig` (inline)

Pure module, peer to `skill_registry.zig`. Scans a directory for `*.md` files; each file is one command. Frontmatter (`---` fenced) provides `name` (required), `description` (optional), `action` (optional, raw string). Body after the closing `---` is the prompt template. Validation of `action` against the known action vocabulary happens in `ai_chat.zig` (Task 5), keeping this module independent.

- [ ] **Step 1: Write the failing test** (inline):

```zig
const std = @import("std");

test "parseCommandFile reads name, description, action, and body" {
    const a = std.testing.allocator;
    const src =
        "---\nname: review\ndescription: review the diff\naction: \n---\nPlease review the current git diff.\n";
    var cmd = (try parseCommandFile(a, src)).?;
    defer cmd.deinit(a);
    try std.testing.expectEqualStrings("review", cmd.name);
    try std.testing.expectEqualStrings("review the diff", cmd.description);
    try std.testing.expectEqual(@as(?[]const u8, null), cmd.action);
    try std.testing.expectEqualStrings("Please review the current git diff.", std.mem.trim(u8, cmd.body, " \t\r\n"));
}

test "parseCommandFile reads action mapping" {
    const a = std.testing.allocator;
    const src = "---\nname: clear\naction: clear_context\n---\n";
    var cmd = (try parseCommandFile(a, src)).?;
    defer cmd.deinit(a);
    try std.testing.expectEqualStrings("clear_context", cmd.action.?);
}

test "parseCommandFile rejects missing name" {
    const a = std.testing.allocator;
    try std.testing.expectEqual(@as(?CustomCommand, null), try parseCommandFile(a, "---\ndescription: x\n---\nbody"));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | head -40`
Expected: FAIL — file/module not found.

- [ ] **Step 3: Implement the module.** Use `skill_registry.zig`'s frontmatter parsing as the reference (`parseSkillMeta`). Full module:

```zig
//! Pure scan/parse of the user `commands/` directory into slash commands.
//! Peer to skill_registry.zig: text + dir -> command data; no Session state,
//! no networking. Each *.md file is one command.
const std = @import("std");

pub const MAX_COMMAND_MD_BYTES: usize = 256 * 1024;

pub const CustomCommand = struct {
    name: []u8,
    description: []u8,
    action: ?[]u8, // raw frontmatter value; validated by the caller
    body: []u8, // prompt template when action == null

    pub fn deinit(self: *CustomCommand, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
        if (self.action) |a| allocator.free(a);
        allocator.free(self.body);
        self.* = undefined;
    }
};

/// Parse one command file's bytes. Returns null when there is no `name:`.
pub fn parseCommandFile(allocator: std.mem.Allocator, bytes: []const u8) !?CustomCommand {
    var name: ?[]const u8 = null;
    var description: []const u8 = "";
    var action: ?[]const u8 = null;
    var body_start: usize = 0;

    var rest = bytes;
    if (std.mem.startsWith(u8, std.mem.trimLeft(u8, bytes, " \t\r\n"), "---")) {
        // find frontmatter block between the first and second '---' lines
        const after_open = std.mem.indexOfScalar(u8, bytes, '\n') orelse return null;
        const fm_region = bytes[after_open + 1 ..];
        const close_rel = std.mem.indexOf(u8, fm_region, "\n---") orelse return null;
        const fm = fm_region[0..close_rel];
        body_start = after_open + 1 + close_rel + 1; // past "\n"
        // skip the closing "---" line
        if (std.mem.indexOfScalar(u8, bytes[body_start..], '\n')) |nl| body_start += nl + 1;
        rest = fm;
        var it = std.mem.splitScalar(u8, fm, '\n');
        while (it.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r");
            if (line.len == 0) continue;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const key = std.mem.trim(u8, line[0..colon], " \t");
            const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
            if (std.mem.eql(u8, key, "name")) {
                name = value;
            } else if (std.mem.eql(u8, key, "description")) {
                description = value;
            } else if (std.mem.eql(u8, key, "action")) {
                if (value.len > 0) action = value;
            }
        }
    }

    const cmd_name = name orelse return null;
    if (cmd_name.len == 0) return null;
    const body = if (body_start < bytes.len) bytes[body_start..] else "";

    const owned_name = try allocator.dupe(u8, cmd_name);
    errdefer allocator.free(owned_name);
    const owned_desc = try allocator.dupe(u8, description);
    errdefer allocator.free(owned_desc);
    const owned_action = if (action) |av| try allocator.dupe(u8, av) else null;
    errdefer if (owned_action) |av| allocator.free(av);
    const owned_body = try allocator.dupe(u8, body);

    return .{ .name = owned_name, .description = owned_desc, .action = owned_action, .body = owned_body };
}

pub fn freeCommandList(allocator: std.mem.Allocator, commands: []CustomCommand) void {
    for (commands) |*c| c.deinit(allocator);
    allocator.free(commands);
}

/// Scan `commands_rel` under `root_dir` for `*.md` files. Missing dir -> empty.
pub fn listCommands(allocator: std.mem.Allocator, root_dir: std.fs.Dir, commands_rel: []const u8) ![]CustomCommand {
    var list: std.ArrayListUnmanaged(CustomCommand) = .empty;
    errdefer freeCommandListBuilder(allocator, &list);

    var dir = root_dir.openDir(commands_rel, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return allocator.alloc(CustomCommand, 0),
        else => return err,
    };
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".md")) continue;
        const bytes = dir.readFileAlloc(allocator, entry.name, MAX_COMMAND_MD_BYTES) catch continue;
        defer allocator.free(bytes);
        if (try parseCommandFile(allocator, bytes)) |cmd| {
            list.append(allocator, cmd) catch |err| {
                var c = cmd;
                c.deinit(allocator);
                return err;
            };
        }
    }
    return list.toOwnedSlice(allocator);
}

fn freeCommandListBuilder(allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged(CustomCommand)) void {
    for (list.items) |*c| c.deinit(allocator);
    list.deinit(allocator);
}
```

> Note for the implementer: verify `dir.readFileAlloc` signature against the installed Zig (this repo's `skill_registry.zig` `readSkillMarkdown` shows the exact idiom — copy it if the signature differs). Keep behavior identical: skip unreadable/oversized files.

- [ ] **Step 4: Register the module's tests** — add to `src/test_fast.zig`:

```zig
test {
    _ = @import("command_registry.zig");
}
```

(Match the existing import style in that file; if it uses a single `test {}` block with many `_ = @import`, add one line there instead.)

- [ ] **Step 5: Run tests to verify they pass**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS (3 new tests).

- [ ] **Step 6: Commit**

```bash
git add src/command_registry.zig src/test_fast.zig
git commit -m "feat(ai-chat): add command_registry for commands/ directory"
```

---

## Task 5: Load custom commands into the Session + root paths

**Files:**
- Modify: `src/ai_chat.zig` (add `defaultCommandRootPaths`, Session field, loader)
- Test: `src/ai_chat.zig` (inline, using a temp dir like the existing skills tests at `:4366`)

- [ ] **Step 1: Write the failing test** (inline; mirror the skills temp-dir test at `:4366`):

```zig
test "session loads custom commands from a commands directory" {
    const a = std.testing.allocator;
    const root = "zig-cache/tmp/cmdtest";
    try std.fs.cwd().makePath(root ++ "/commands");
    defer std.fs.cwd().deleteTree(root) catch {};
    try std.fs.cwd().writeFile(.{ .sub_path = root ++ "/commands/review.md", .data = "---\nname: review\ndescription: review diff\n---\nReview the diff." });

    var dir = try std.fs.cwd().openDir(root, .{});
    defer dir.close();
    const cmds = try command_registry.listCommands(a, dir, "commands");
    defer command_registry.freeCommandList(a, cmds);
    try std.testing.expectEqual(@as(usize, 1), cmds.len);
    try std.testing.expectEqualStrings("review", cmds[0].name);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | head -40`
Expected: FAIL — `command_registry` not imported in `ai_chat.zig`.

- [ ] **Step 3: Add the import + root paths + Session field.**

At the imports near `ai_chat.zig:16`:
```zig
const command_registry = @import("command_registry.zig");
```

Add `defaultCommandRootPaths` next to `defaultSkillRootPaths` (`:513`), mirroring it but with `"commands"` and `platform_dirs.commandsDir` (add that helper in `platform/dirs.zig` returning `<config>/commands`; copy the `skillsDir` implementation and swap the last path segment):
```zig
fn defaultCommandRootPaths(allocator: std.mem.Allocator) ![][]const u8 {
    var roots: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer { for (roots.items) |r| allocator.free(r); roots.deinit(allocator); }
    if (platform_dirs.commandsDir(allocator)) |d| {
        try appendOwnedSkillRootPath(allocator, &roots, d);
    } else |_| {}
    try appendSkillRootPath(allocator, &roots, "commands");
    return roots.toOwnedSlice(allocator);
}
```

Add a Session field (near the other suggestion state, e.g. by `skill_suggestions`):
```zig
custom_commands: []command_registry.CustomCommand = &.{},
```

Add a loader method that scans all roots, concatenates, and validates each `action` against the known vocabulary (unknown action → skip + log; first-seen name wins; built-in name collision → skip + log). Free `custom_commands` in `Session.deinit` via `command_registry.freeCommandList`. (The `customCommandSuggestions()` projection used by the composer is built in Task 6, not here — Task 5 only loads/stores `custom_commands`.)

```zig
fn knownActionFromName(value: []const u8) ?SlashCommand {
    if (std.mem.eql(u8, value, "clear_context")) return .clear;
    if (std.mem.eql(u8, value, "restore_session")) return .resume_session;
    if (std.mem.eql(u8, value, "set_permission")) return .permission;
    if (std.mem.eql(u8, value, "export_markdown")) return .export_markdown;
    return null;
}

pub fn reloadCustomCommands(self: *Session) void {
    const roots = defaultCommandRootPaths(self.allocator) catch return;
    defer freeSkillRootPaths(self.allocator, roots);
    var merged: std.ArrayListUnmanaged(command_registry.CustomCommand) = .empty;
    for (roots) |root| {
        var dir = openDirectoryPath(root) catch continue;
        defer dir.close();
        const cmds = command_registry.listCommands(self.allocator, dir, "") catch continue;
        defer self.allocator.free(cmds);
        for (cmds) |cmd| {
            var c = cmd;
            // skip if it duplicates a built-in or an already-loaded custom name,
            // or declares an unknown action
            if (c.action) |av| if (knownActionFromName(av) == null) { c.deinit(self.allocator); continue; };
            // Dedup ONLY against built-ins and commands already merged in THIS reload.
            // Do NOT check self.custom_commands — it is the old list being replaced;
            // checking it would reject everything on a reload.
            if (isBuiltinCommandName(c.name) or hasName(merged.items, c.name)) { c.deinit(self.allocator); continue; }
            merged.append(self.allocator, c) catch { c.deinit(self.allocator); break; };
        }
    }
    command_registry.freeCommandList(self.allocator, self.custom_commands);
    self.custom_commands = merged.toOwnedSlice(self.allocator) catch &.{};
}
```

> Implementer notes: `openDirectoryPath` already exists (`:506`). `listCommands(dir, "")` scans `dir` itself — adjust `listCommands` to accept `""` meaning "this dir" (the `openDir("", ...)` case) or pass the leaf "commands" and root the parent; pick one and keep it consistent with `defaultCommandRootPaths`. Add small helpers `isBuiltinCommandName` (compare `"/" ++ name` against `slash_command_entries` commands) and `hasName` (scan `merged.items`). Call `reloadCustomCommands` once during session init after settings are copied.

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/ai_chat.zig src/platform/dirs.zig
git commit -m "feat(ai-chat): load custom commands from commands/ into the session"
```

---

## Task 6: Thread custom commands into suggestions + dispatch

**Files:**
- Modify: `src/ai_chat_composer.zig` (suggestion/parse functions gain `custom` param)
- Modify: `src/ai_chat.zig` (`:843-858` wrappers; dispatch `:1371`)
- Test: `src/ai_chat_composer.zig` + `src/ai_chat.zig` (inline)

- [ ] **Step 1: Write the failing test** (composer; custom command appears in suggestions):

```zig
test "slash suggestions include custom commands" {
    const custom = [_]SlashCommandSuggestion{.{ .command = "/review", .description = "review diff" }};
    // "/re" should match the built-in "/reload-*" entries AND the custom "/review"
    const count = slashCommandSuggestionCountForInput("/rev", 4, &custom);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqualStrings("/review", slashCommandSuggestionAtForInput("/rev", 4, 0, &custom).?.command);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | head -40`
Expected: FAIL — too many/few args to `slashCommandSuggestionCountForInput`.

- [ ] **Step 3: Add `custom: []const SlashCommandSuggestion` as the trailing param** to `slashCommandSuggestionCountForInput` (`:105`), `slashCommandSuggestionAtForInput` (`:114`), and have them iterate built-in `slash_command_entries` first, then `custom`. Thread the param through `composerSuggestionCountForInput`/`composerSuggestionAtForInput` (`:125`,`:133`). Add `parseSlashCommand` handling for custom: keep `parseSlashCommand(input) ?SlashCommand` for built-ins and add a separate pure helper:

```zig
pub fn matchCustomCommandIndex(input: []const u8, custom: []const SlashCommandSuggestion) ?usize {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, "/")) return null;
    // first token only (so "/review extra args" still matches "/review")
    const tok_end = slashCommandTokenEnd(trimmed);
    const tok = trimmed[0..tok_end];
    for (custom, 0..) |c, i| if (std.mem.eql(u8, tok, c.command)) return i;
    return null;
}
```

- [ ] **Step 4: Update existing composer call sites + tests** to pass `&.{}` for `custom` where there are no custom commands (existing tests at `:241+`). Update the `pub const` re-exports at `ai_chat.zig:355-362` if signatures changed (they re-export the same fns).

- [ ] **Step 5: Update the Session wrappers** (`ai_chat.zig:843-858`) to pass `self.customCommandSuggestions()`:

```zig
pub fn slashCommandSuggestionCount(self: *Session) usize {
    return slashCommandSuggestionCountForInput(self.input(), self.input_cursor, self.customCommandSuggestions());
}
```
(and `slashCommandSuggestionAt`, `slashCommandSuggestionSelectedIndex` similarly). `customCommandSuggestions()` builds a stack/temature slice — since the suggestion list must outlive the call, store a cached `[]SlashCommandSuggestion` rebuilt in `reloadCustomCommands` alongside `custom_commands`.

- [ ] **Step 6: Update dispatch** at `ai_chat.zig:1371`. Built-in commands must support an optional argument (`/permission full`, `/export full`). `parseSlashCommand` (`:64`) rejects any input containing a space, so the dispatch must **exact-match the first token** for built-ins, while preserving today's fall-through for non-command inputs like `/help me` (which should still be sent to the model, not treated as a command).

Add a pure helper in `ai_chat_composer.zig` that exact-matches the first token to a built-in entry and NEVER returns `.unknown`:

```zig
pub fn exactBuiltinCommand(token: []const u8) ?SlashCommand {
    for (slash_command_entries) |entry| {
        if (std.mem.eql(u8, token, entry.suggestion.command)) return entry.action;
    }
    return null;
}
```

Replace the dispatch head at `:1371` (the `if (parseSlashCommand(prompt_raw)) |command| { ... }` block) with first-token resolution:

```zig
const tok_end = ai_chat_composer.slashCommandTokenEnd(prompt_raw);
const first_tok = prompt_raw[0..tok_end];
const arg = std.mem.trim(u8, prompt_raw[tok_end..], " \t\r\n");

// 1) Built-in command (with optional argument), exact first-token match.
if (exactBuiltinCommand(first_tok)) |command| {
    self.runBuiltinCommandLocked(command, arg);
    history_change = null;
    self.mutex.unlock();
    return;
}
// 2) Custom command, matched by first token.
if (matchCustomCommandIndex(first_tok, self.customCommandSuggestions())) |idx| {
    const cmd = self.custom_commands[idx];
    if (cmd.action) |av| {
        if (knownActionFromName(av)) |builtin| {
            self.runBuiltinCommandLocked(builtin, arg);
            history_change = null;
            self.mutex.unlock();
            return;
        }
    }
    // prompt template: replace input with the template body, then fall through to
    // the normal user-message submit path below (do NOT return).
    self.setInputText(cmd.body);
}
// 3) Legacy: a no-arg unknown slash like "/help" still shows "Unknown command".
else if (arg.len == 0) {
    if (parseSlashCommand(prompt_raw)) |command| { // returns .unknown for "/help"
        self.runBuiltinCommandLocked(command, "");
        history_change = null;
        self.mutex.unlock();
        return;
    }
}
// Otherwise (e.g. "/help me", "/usr/bin path"): fall through to normal model submit.
```

`runBuiltinCommandLocked(self, command, arg)` extracts the existing `:1377-1398` body (append `slashCommandOutput`, `clearSubmittedInputLocked`, set status) and adds the side-effects:
- `.clear` → call `self.clearMessagesLocked()` (mutex already held in dispatch) **before** appending the confirmation line; capture its returned `?PendingHistoryChange` into the dispatch's `history_change` so it is notified after unlock (instead of setting `history_change = null` for this command). The confirmation line is appended after the clear so it survives.
- `.reload_commands` → `self.reloadCustomCommands()`.
- `.reload_skills` → `self.freeSkillSuggestions()` (as today).
- `.update_skills` → fire `g_skill_update_trigger` (as today).
- `.permission` → `applyPermissionArg(arg)` (Task 7) **before** producing the `.permission` output, so the status line reflects the new value.
- `.resume_session` → fire `g_session_resume_trigger` (Task 8).
- `.export_markdown` → `fireExportCommand(arg)` (Task 8; default mode clean).

> Note: this preserves all current behavior — `/skills`,`/commands`,`/reload-skills`,`/update-skills` exact-match as before; `/help` (no arg) still shows "Unknown command"; `/help me` and slashes containing `/` still fall through to the model. New: `/permission full`, `/export full`, and `/<custom> args` now route correctly.

- [ ] **Step 7: Run tests to verify they pass**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add src/ai_chat_composer.zig src/ai_chat.zig
git commit -m "feat(ai-chat): dispatch + suggest custom slash commands"
```

---

## Task 7: `/permission` arg + runtime toggle

**Files:**
- Modify: `src/ai_chat.zig` (`runBuiltinCommandLocked` permission branch)
- Test: `src/ai_chat.zig` (inline)

- [ ] **Step 1: Write the failing test:**

```zig
test "/permission full flips the global agent permission" {
    configureAgent(.{ .permission = .confirm });
    // simulate dispatch of "/permission full"
    applyPermissionArg("full");
    try std.testing.expectEqual(AgentPermission.full, currentAgentSettings().permission);
    configureAgent(.{ .permission = .confirm }); // restore
}
```

- [ ] **Step 2: Run test to verify it fails** — `applyPermissionArg` undefined.

Run: `zig build test 2>&1 | head -40`

- [ ] **Step 3: Implement `applyPermissionArg`** and call it from the permission branch of `runBuiltinCommandLocked`:

```zig
fn applyPermissionArg(arg: []const u8) void {
    const trimmed = std.mem.trim(u8, arg, " \t\r\n");
    if (trimmed.len == 0) return; // no-arg = status only (output already emitted)
    if (AgentPermission.parse(trimmed)) |p| {
        var s = currentAgentSettings();
        s.permission = p;
        configureAgent(s);
    }
}
```

The permission branch emits status via `permissionStatusOutput` (Task 2) AFTER applying the arg, so the confirmation reflects the new value.

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test 2>&1 | tail -20`

- [ ] **Step 5: Commit**

```bash
git add src/ai_chat.zig
git commit -m "feat(ai-chat): /permission [confirm|full] runtime toggle"
```

---

## Task 8: `/resume` + `/export` startup callbacks

**Files:**
- Modify: `src/ai_chat.zig` (two new global callbacks, mirroring `:317`)
- Modify: `src/AppWindow.zig` (register them at startup)
- Test: `src/ai_chat.zig` (inline, capture-hook style)

- [ ] **Step 1: Write the failing test:**

```zig
var test_export_mode: ?MarkdownExportMode = null;
fn testExportHook(mode: MarkdownExportMode) void { test_export_mode = mode; }

test "/export fires the export trigger with parsed mode" {
    setMarkdownExportTrigger(testExportHook);
    defer setMarkdownExportTrigger(null);
    test_export_mode = null;
    fireExportCommand("full");
    try std.testing.expectEqual(MarkdownExportMode.full, test_export_mode.?);
    fireExportCommand("");
    try std.testing.expectEqual(MarkdownExportMode.clean, test_export_mode.?); // default clean
}
```

- [ ] **Step 2: Run test to verify it fails** — `setMarkdownExportTrigger`/`fireExportCommand` undefined.

Run: `zig build test 2>&1 | head -40`

- [ ] **Step 3: Add the callbacks** next to `g_skill_update_trigger` (`:317`):

```zig
var g_session_resume_trigger: ?*const fn () void = null;
var g_markdown_export_trigger: ?*const fn (MarkdownExportMode) void = null;

pub fn setSessionResumeTrigger(cb: ?*const fn () void) void { g_session_resume_trigger = cb; }
pub fn setMarkdownExportTrigger(cb: ?*const fn (MarkdownExportMode) void) void { g_markdown_export_trigger = cb; }

fn fireExportCommand(arg: []const u8) void {
    const mode: MarkdownExportMode = if (std.mem.eql(u8, std.mem.trim(u8, arg, " \t\r\n"), "full")) .full else .clean;
    if (g_markdown_export_trigger) |t| t(mode);
}
```

Wire `g_session_resume_trigger` into the `.resume_session` branch and `fireExportCommand` into the `.export_markdown` branch of `runBuiltinCommandLocked`.

- [ ] **Step 4: Register in AppWindow** — find the `ai_chat.setSkillUpdateTrigger(...)` call site in `AppWindow.zig` and add next to it:

```zig
ai_chat.setMarkdownExportTrigger(struct {
    fn cb(mode: ai_chat.MarkdownExportMode) void { exportActiveAiChatMarkdown(mode); }
}.cb);
ai_chat.setSessionResumeTrigger(struct {
    fn cb() void { openAiChatHistoryPicker(); }
}.cb);
```

`openAiChatHistoryPicker` = the existing entry point that opens the agent history picker overlay (find it via the `command_center_state` history-picker mode; reuse whatever the Command Palette uses to enter that mode). If a direct function does not exist, add a thin wrapper that sets the command-center into history-picker mode.

- [ ] **Step 5: Run tests + build to verify**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/ai_chat.zig src/AppWindow.zig
git commit -m "feat(ai-chat): wire /resume and /export to app-layer callbacks"
```

---

## Task 9: Cross-target build + full test sweep

- [ ] **Step 1:** `zig build test 2>&1 | tail -30` — all green.
- [ ] **Step 2:** `zig build test-full -Dtarget=x86_64-windows-gnu 2>&1 | tail -30` — expect the known baseline 497/499 (1 known Windows-API failure, 1 skip) per memory `phantty-test-execution-env`; no NEW failures.
- [ ] **Step 3:** Manually create `~/.config/wispterm/commands/hello.md` with a prompt template and one with `action: clear_context`; launch the app, type `/` and confirm both appear in suggestions, `/clear` empties the transcript, `/permission full` reports the change, `/export` writes a file, `/resume` opens the picker.
- [ ] **Step 4: Commit** any doc updates (e.g. `docs/ai-agent.md` mention of commands/).

---

## Self-review notes (coverage)

- 需求1 commands/ dir → Tasks 4,5,6. Action mapping + prompt template → Task 6. Reload → `/reload-commands` Tasks 1,2,6.
- 需求2 `/clear` → Task 3,6; `/export` (default clean) → Task 8; `/permission` → Task 7; `/resume` → Task 8.
- Built-in > custom name precedence → Task 5 (`isBuiltinCommandName` skip).
- Test inclusion → Task 4 Step 4.
- Open implementer verifications flagged inline: `Message.deinit` signature, `dir.readFileAlloc` idiom, `platform_dirs.commandsDir` addition, the existing history-picker entry point name.
