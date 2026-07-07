# AI History Actions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add selected-session actions to AI History: download the raw provider file, export a Markdown transcript, and attach the transcript as Copilot context.

**Architecture:** Keep pure export formatting in `terminal_agents/sessions/markdown.zig`, session ownership helpers in `terminal_agents/sessions/session.zig`, and UI/IO orchestration in `AppWindow.zig`. Reuse existing file dialogs, atomic writes, WSL/SSH remote read helpers, file explorer SCP downloads, Copilot session creation, and AI Chat history hooks. Ghostty has no equivalent AI-history surface, so terminal core and VT/rendering behavior remain untouched.

**Tech Stack:** Zig, existing WispTerm AI History modules, existing AppWindow/Copilot integration, `zig build test`, `zig build test-full`.

---

## File Map

- Create `src/terminal_agents/sessions/markdown.zig`: pure Markdown export, bounded Copilot context, raw download filename sanitization.
- Modify `src/test_fast.zig`: import the new pure module into the fast suite.
- Modify `src/test_main.zig`: import the new module into the full assistant shard.
- Modify `src/terminal_agents/sessions/session.zig`: selected metadata clone, transcript clone, preview replacement helpers.
- Modify `src/assistant/conversation/session.zig`: append a collapsed context card that persists to Copilot history.
- Modify `src/appwindow/tab.zig`: spawn an AI Chat tab from an already-created `ai_chat.Session`.
- Modify `src/renderer/terminal_agents/sessions.zig`: render and hit-test `Download Raw`, `Export Markdown`, and `Attach to Copilot` buttons.
- Modify `src/AppWindow.zig`: implement selected AI History action entry points and raw/Markdown save flows.
- Modify `src/input.zig`: route `D`, `M`, and `A` while AI History search is not focused.
- Modify `src/source_guards/side_effect_guard.zig`: lower the AppWindow direct dirty-write ceiling after converting one legacy direct write to `markUiDirty()`.
- Modify `README.md` and `docs/ai-agent.md`: document the new AI History actions and shortcuts.

---

### Task 1: Add Pure AI History Markdown Export Module

**Files:**
- Create: `src/terminal_agents/sessions/markdown.zig`
- Modify: `src/test_fast.zig`
- Modify: `src/test_main.zig`

- [ ] **Step 1: Write the failing formatter tests**

Create `src/terminal_agents/sessions/markdown.zig` with tests first:

```zig
const std = @import("std");
const types = @import("types.zig");

test "ai history markdown export includes metadata and role sections" {
    const allocator = std.testing.allocator;
    const meta = types.SessionMeta{
        .provider = .codex,
        .session_id = "sess-1",
        .title = "Fix renderer",
        .project_dir = "/work/wispterm",
        .source_path = "/home/me/.codex/sessions/sess-1.jsonl",
        .resume_kind = .codex_resume,
        .created_at_ms = 1000,
        .last_active_at_ms = 2000,
    };
    const messages = [_]types.TranscriptMessage{
        .{ .role = .user, .content = "status?", .timestamp_ms = 1100 },
        .{ .role = .assistant, .content = "ready", .timestamp_ms = 1200 },
        .{ .role = .tool, .content = "tool output", .timestamp_ms = 1300 },
    };

    const markdown = try allocMarkdownExport(allocator, meta, &messages, .{});
    defer allocator.free(markdown);

    try std.testing.expect(std.mem.indexOf(u8, markdown, "# AI History Export") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "- Provider: Codex") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "- Session: sess-1") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "- Project: /work/wispterm") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "## User") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "status?") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "## Assistant") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "ready") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "## Tool") != null);
}

test "ai history markdown export skips empty message bodies" {
    const allocator = std.testing.allocator;
    const meta = types.SessionMeta{
        .provider = .claude,
        .session_id = "sess-2",
        .title = "Empty turn",
        .source_path = "/home/me/.claude/projects/sess-2.jsonl",
        .resume_kind = .claude_resume,
    };
    const messages = [_]types.TranscriptMessage{
        .{ .role = .system, .content = "" },
        .{ .role = .assistant, .content = "answer" },
    };

    const markdown = try allocMarkdownExport(allocator, meta, &messages, .{});
    defer allocator.free(markdown);

    try std.testing.expect(std.mem.indexOf(u8, markdown, "## System") == null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "## Assistant") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "answer") != null);
}
```

- [ ] **Step 2: Register the new module in test aggregators**

In `src/test_fast.zig`, add this import near the other `terminal_agents/sessions/*` imports:

```zig
    _ = @import("terminal_agents/sessions/markdown.zig");
```

In `src/test_main.zig`, add this import in the `.assistant` shard near `terminal_agents/sessions/session.zig`:

```zig
        _ = @import("terminal_agents/sessions/markdown.zig");
```

- [ ] **Step 3: Run the failing tests**

Run:

```bash
zig build test
```

Expected: FAIL because `allocMarkdownExport` is not defined.

- [ ] **Step 4: Implement minimal Markdown export**

Replace the top of `src/terminal_agents/sessions/markdown.zig` with this implementation, keeping the tests below it:

```zig
const std = @import("std");
const types = @import("types.zig");

pub const ExportOptions = struct {};

pub fn allocMarkdownExport(
    allocator: std.mem.Allocator,
    meta: types.SessionMeta,
    messages: []const types.TranscriptMessage,
    _: ExportOptions,
) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try appendHeader(allocator, &out, meta);

    var wrote_message = false;
    for (messages) |msg| {
        const body = std.mem.trim(u8, msg.content, " \t\r\n");
        if (body.len == 0) continue;
        try appendMessage(allocator, &out, msg.role, body);
        wrote_message = true;
    }
    if (!wrote_message) try out.appendSlice(allocator, "_No transcript messages._\n");

    return out.toOwnedSlice(allocator);
}

fn appendHeader(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), meta: types.SessionMeta) !void {
    try out.appendSlice(allocator, "# AI History Export\n\n");
    try out.writer(allocator).print("- Provider: {s}\n", .{meta.provider.label()});
    try out.writer(allocator).print("- Session: {s}\n", .{meta.session_id});
    if (meta.title.len > 0) try out.writer(allocator).print("- Title: {s}\n", .{meta.title});
    if (meta.project_dir.len > 0) try out.writer(allocator).print("- Project: {s}\n", .{meta.project_dir});
    try out.writer(allocator).print("- Source: {s}\n", .{meta.source_path});
    if (meta.created_at_ms > 0) try out.writer(allocator).print("- Created: {d}\n", .{meta.created_at_ms});
    if (meta.last_active_at_ms > 0) try out.writer(allocator).print("- Updated: {d}\n", .{meta.last_active_at_ms});
    try out.appendSlice(allocator, "\n");
}

fn appendMessage(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    role: types.MessageRole,
    body: []const u8,
) !void {
    try out.writer(allocator).print("## {s}\n\n", .{roleHeading(role)});
    try out.appendSlice(allocator, body);
    if (!std.mem.endsWith(u8, body, "\n")) try out.append(allocator, '\n');
    try out.append(allocator, '\n');
}

fn roleHeading(role: types.MessageRole) []const u8 {
    return switch (role) {
        .user => "User",
        .assistant => "Assistant",
        .system => "System",
        .tool => "Tool",
    };
}
```

- [ ] **Step 5: Run tests**

Run:

```bash
zig build test
```

Expected: PASS for the new Markdown export tests and existing fast tests.

- [ ] **Step 6: Commit**

```bash
git add src/terminal_agents/sessions/markdown.zig src/test_fast.zig src/test_main.zig
git commit -m "feat: add ai history markdown export formatter"
```

---

### Task 2: Add Bounded Copilot Context and Raw Filename Helpers

**Files:**
- Modify: `src/terminal_agents/sessions/markdown.zig`

- [ ] **Step 1: Write failing tests for context truncation and filename sanitization**

Append these tests to `src/terminal_agents/sessions/markdown.zig`:

```zig
test "ai history copilot context truncates oversized transcripts from the front" {
    const allocator = std.testing.allocator;
    const meta = types.SessionMeta{
        .provider = .reasonix,
        .session_id = "sess-3",
        .title = "Long chat",
        .source_path = "/home/me/.reasonix/sessions/events.jsonl",
        .resume_kind = .reasonix_resume,
    };
    const messages = [_]types.TranscriptMessage{
        .{ .role = .user, .content = "old prompt that should drop" },
        .{ .role = .assistant, .content = "old answer that should drop" },
        .{ .role = .user, .content = "recent prompt" },
        .{ .role = .assistant, .content = "recent answer" },
    };

    var result = try allocCopilotContext(allocator, meta, &messages, 260);
    defer result.deinit(allocator);

    try std.testing.expect(result.truncated);
    try std.testing.expect(std.mem.indexOf(u8, result.markdown, "Transcript truncated") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.markdown, "recent prompt") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.markdown, "recent answer") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.markdown, "old prompt that should drop") == null);
}

test "ai history raw download filename sanitizes provider session and basename" {
    var buf: [160]u8 = undefined;
    const meta = types.SessionMeta{
        .provider = .claude,
        .session_id = "session:bad/id",
        .title = "Ignored",
        .source_path = "/home/me/.claude/projects/original file.jsonl",
        .resume_kind = .claude_resume,
    };

    const name = rawDownloadFilename(meta, &buf);
    try std.testing.expectEqualStrings("claude-code-session-bad-id-original-file.jsonl", name);
}
```

- [ ] **Step 2: Run the failing tests**

Run:

```bash
zig build test
```

Expected: FAIL because `allocCopilotContext`, `ContextResult`, `deinit`, and `rawDownloadFilename` are not defined.

- [ ] **Step 3: Implement context and filename helpers**

Add this code above the tests in `src/terminal_agents/sessions/markdown.zig`:

```zig
pub const ContextResult = struct {
    markdown: []u8,
    truncated: bool,

    pub fn deinit(self: *ContextResult, allocator: std.mem.Allocator) void {
        allocator.free(self.markdown);
        self.truncated = false;
    }
};

pub fn allocCopilotContext(
    allocator: std.mem.Allocator,
    meta: types.SessionMeta,
    messages: []const types.TranscriptMessage,
    max_bytes: usize,
) !ContextResult {
    const full = try allocMarkdownExport(allocator, meta, messages, .{});
    if (full.len <= max_bytes) {
        return .{ .markdown = full, .truncated = false };
    }
    allocator.free(full);

    var start = messages.len;
    while (start > 0) {
        const candidate = try allocMarkdownExportWithNotice(allocator, meta, messages[start - 1 ..], true);
        defer allocator.free(candidate);
        if (candidate.len > max_bytes and start < messages.len) break;
        start -= 1;
        if (candidate.len <= max_bytes and start == 0) break;
    }

    const tail_start = @min(start + 1, messages.len);
    const markdown = try allocMarkdownExportWithNotice(allocator, meta, messages[tail_start..], true);
    return .{ .markdown = markdown, .truncated = true };
}

fn allocMarkdownExportWithNotice(
    allocator: std.mem.Allocator,
    meta: types.SessionMeta,
    messages: []const types.TranscriptMessage,
    truncated: bool,
) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try appendHeader(allocator, &out, meta);
    if (truncated) try out.appendSlice(allocator, "_Transcript truncated; showing the most recent messages._\n\n");
    var wrote_message = false;
    for (messages) |msg| {
        const body = std.mem.trim(u8, msg.content, " \t\r\n");
        if (body.len == 0) continue;
        try appendMessage(allocator, &out, msg.role, body);
        wrote_message = true;
    }
    if (!wrote_message) try out.appendSlice(allocator, "_No transcript messages._\n");
    return out.toOwnedSlice(allocator);
}

pub fn rawDownloadFilename(meta: types.SessionMeta, out: []u8) []const u8 {
    const provider = sanitizedProviderLabel(meta.provider);
    const base = std.fs.path.basename(meta.source_path);
    var tmp: [256]u8 = undefined;
    const raw = std.fmt.bufPrint(&tmp, "{s}-{s}-{s}", .{ provider, meta.session_id, base }) catch provider;
    return sanitizeFilename(raw, out);
}

fn sanitizedProviderLabel(provider: types.ProviderId) []const u8 {
    return switch (provider) {
        .codex => "codex",
        .claude => "claude-code",
        .reasonix => "reasonix",
    };
}

fn sanitizeFilename(raw: []const u8, out: []u8) []const u8 {
    if (out.len == 0) return "";
    var n: usize = 0;
    var last_dash = false;
    for (raw) |ch| {
        if (n >= out.len) break;
        const ok = std.ascii.isAlphanumeric(ch) or ch == '.' or ch == '_' or ch == '-';
        const next = if (ok) std.ascii.toLower(ch) else '-';
        if (next == '-' and last_dash) continue;
        out[n] = next;
        n += 1;
        last_dash = next == '-';
    }
    while (n > 0 and out[n - 1] == '-') n -= 1;
    return out[0..n];
}
```

- [ ] **Step 4: Run tests**

Run:

```bash
zig build test
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/terminal_agents/sessions/markdown.zig
git commit -m "feat: bound ai history copilot context exports"
```

---

### Task 3: Add AI History Session Ownership Helpers

**Files:**
- Modify: `src/terminal_agents/sessions/session.zig`

- [ ] **Step 1: Write failing session helper tests**

Append these tests near the existing `ai_history_session` tests in `src/terminal_agents/sessions/session.zig`:

```zig
test "ai_history_session: selectedMetadataClone owns selected row strings" {
    const allocator = std.testing.allocator;
    var session = Session.init(allocator, .{ .id = "local", .name = "Local", .target = .local });
    defer session.deinit();

    const rows = [_]types.SessionMeta{.{
        .provider = .codex,
        .session_id = "s1",
        .title = "Title",
        .project_dir = "/work",
        .source_path = "/tmp/s1.jsonl",
        .resume_kind = .codex_resume,
    }};
    try session.replaceRows(&rows);

    const cloned = session.selectedMetadataClone(allocator) orelse return error.MissingClone;
    defer freeMetadata(allocator, cloned);

    try session.replaceRows(&.{});
    try std.testing.expectEqualStrings("s1", cloned.session_id);
    try std.testing.expectEqualStrings("/tmp/s1.jsonl", cloned.source_path);
}

test "ai_history_session: replaceTranscriptFromMessages installs ready transcript" {
    const allocator = std.testing.allocator;
    var session = Session.init(allocator, .{ .id = "local", .name = "Local", .target = .local });
    defer session.deinit();

    const messages = try allocator.alloc(types.TranscriptMessage, 1);
    messages[0] = .{
        .role = .assistant,
        .content = try allocator.dupe(u8, "ready"),
    };

    session.replaceTranscriptFromMessages(.codex, messages);

    session.mutex.lock();
    defer session.mutex.unlock();
    try std.testing.expectEqual(TranscriptState.ready, session.transcript_state);
    try std.testing.expectEqual(types.ProviderId.codex, session.transcript_provider.?);
    try std.testing.expectEqualStrings("ready", session.transcript[0].content);
}
```

- [ ] **Step 2: Run the failing tests**

Run:

```bash
zig build test
```

Expected: FAIL because `selectedMetadataClone` and `replaceTranscriptFromMessages` are not defined.

- [ ] **Step 3: Implement helpers**

Inside `pub const Session = struct`, add these methods near `selectedVisible` and `clearTranscript`:

```zig
    pub fn selectedMetadataClone(self: *Session, allocator: std.mem.Allocator) ?types.SessionMeta {
        self.mutex.lock();
        defer self.mutex.unlock();
        const selected = self.selectedVisible() orelse return null;
        return cloneMetadata(allocator, selected) catch null;
    }

    pub fn replaceTranscriptFromMessages(self: *Session, provider: types.ProviderId, messages: []types.TranscriptMessage) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.clearTranscript();
        self.transcript = messages;
        self.transcript_provider = provider;
        self.transcript_state = .ready;
        self.transcript_status = "Transcript ready";
        self.transcript_scroll = 0;
    }
```

- [ ] **Step 4: Run tests**

Run:

```bash
zig build test
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/terminal_agents/sessions/session.zig
git commit -m "feat: add ai history selected transcript helpers"
```

---

### Task 4: Add Collapsed Copilot Context Card API

**Files:**
- Modify: `src/assistant/conversation/session.zig`

- [ ] **Step 1: Write the failing context-card test**

Append this test near the other context-summary tests in `src/assistant/conversation/session.zig`:

```zig
test "ai chat appendContextCard stores collapsed persisted user context" {
    const allocator = std.testing.allocator;
    const session = try Session.init(allocator, "Copilot", "https://example.test", "k", "model", "system", "disabled", "low", "false", "true");
    defer session.deinit();

    try session.appendContextCard("AI History: Codex sess-1", "## User\n\nstatus?", true);

    session.mutex.lock();
    defer session.mutex.unlock();
    try std.testing.expectEqual(@as(usize, 1), session.messages.items.len);
    const msg = session.messages.items[0];
    try std.testing.expectEqual(Role.user, msg.role);
    try std.testing.expect(msg.is_context_summary);
    try std.testing.expect(msg.content_collapsed);
    try std.testing.expect(msg.persist_to_history);
    try std.testing.expect(std.mem.indexOf(u8, msg.content, "AI History: Codex sess-1") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg.content, "status?") != null);
}
```

- [ ] **Step 2: Run the failing test**

Run:

```bash
zig build test
```

Expected: FAIL because `appendContextCard` is not defined.

- [ ] **Step 3: Implement context-card append**

Inside `pub const Session = struct`, near `appendInputText`, add:

```zig
    pub fn appendContextCard(self: *Session, title_text: []const u8, body: []const u8, collapsed: bool) !void {
        const content = try std.fmt.allocPrint(self.allocator, "### {s}\n\n{s}", .{ title_text, body });
        var history_change: ?PendingHistoryChange = null;
        self.mutex.lock();
        errdefer {
            self.mutex.unlock();
            self.allocator.free(content);
        }
        try self.messages.append(self.allocator, .{
            .role = .user,
            .content = content,
            .is_context_summary = true,
            .content_collapsed = collapsed,
            .persist_to_history = true,
        });
        history_change = self.captureHistoryChangeLocked();
        self.setStatusLocked("Ready");
        self.mutex.unlock();
        self.notifyHistoryChange(history_change);
    }
```

- [ ] **Step 4: Run tests**

Run:

```bash
zig build test
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/assistant/conversation/session.zig
git commit -m "feat: add copilot context card append API"
```

---

### Task 5: Allow AppWindow to Spawn an AI Chat Tab From an Existing Session

**Files:**
- Modify: `src/appwindow/tab.zig`

- [ ] **Step 1: Write the failing tab helper test**

Append this test near the existing AI Chat tab tests in `src/appwindow/tab.zig`:

```zig
test "tab: spawnAiChatSession creates active ai chat tab from owned session" {
    const allocator = std.testing.allocator;
    resetTestTabGlobals();
    defer {
        for (0..g_tab_count) |idx| {
            if (g_tabs[idx]) |tab_state| {
                tab_state.deinit(allocator);
                allocator.destroy(tab_state);
                g_tabs[idx] = null;
            }
        }
        resetTestTabGlobals();
    }

    const session = try ai_chat.Session.init(allocator, "Copilot", "https://example.test", "k", "model", "system", "disabled", "low", "false", "true");
    try std.testing.expect(spawnAiChatSession(allocator, session));
    try std.testing.expectEqual(@as(usize, 1), g_tab_count);
    try std.testing.expect(activeAiChat() != null);
    try std.testing.expectEqualStrings("Copilot", activeAiChat().?.title());
}
```

- [ ] **Step 2: Run the failing test**

Run:

```bash
zig build test
```

Expected: FAIL because `spawnAiChatSession` is not defined.

- [ ] **Step 3: Implement `spawnAiChatSession` by extracting existing tab setup**

In `src/appwindow/tab.zig`, add this helper near `spawnAiChatTab`:

```zig
pub fn spawnAiChatSession(allocator: std.mem.Allocator, session: *ai_chat.Session) bool {
    if (g_tab_count >= MAX_TABS) return false;
    installAiChatHistoryHook(session);

    const t = allocator.create(TabState) catch return false;
    t.kind = .ai_chat;
    t.tree = .empty;
    t.focused = .root;
    t.ai_chat_session = session;
    t.ai_history_session = null;
    t.skill_center_session = null;
    t.port_forwarding_session = null;
    t.copilot_session = null;
    t.tmux_window_id = null;
    t.tmux_owner = null;
    t.tmux_name_len = 0;
    t.copilot_visible = false;

    g_tabs[g_tab_count] = t;
    active_tab_state.g_active_tab = g_tab_count;
    g_tab_count += 1;
    return true;
}
```

Then replace the duplicated tab setup at the end of `spawnAiChatTab` with:

```zig
    if (!spawnAiChatSession(allocator, session)) {
        session.deinit();
        return false;
    }
    std.debug.print("New AI Chat tab spawned (count={}), active: {}\n", .{ g_tab_count, active_tab_state.g_active_tab });
    return true;
```

- [ ] **Step 4: Run tests**

Run:

```bash
zig build test
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/appwindow/tab.zig
git commit -m "feat: spawn ai chat tab from existing session"
```

---

### Task 6: Add AI History Detail Action Buttons and Hit Tests

**Files:**
- Modify: `src/renderer/terminal_agents/sessions.zig`

- [ ] **Step 1: Write failing renderer hit-test expectations**

In `test "terminal agent sessions renderer: interaction hit test maps buttons and row offset"`, add these expectations after the existing `Hit.@"resume"` assertion:

```zig
    const action_top = detailActionTop(top, cell_h);
    try std.testing.expectEqual(
        Hit.download_raw,
        interactionHitTest(session, 1000, 700, top, 0, 1000, cell_h, layout.detail_x + PAD_X + 4, action_top + 2),
    );
    try std.testing.expectEqual(
        Hit.export_markdown,
        interactionHitTest(session, 1000, 700, top, 0, 1000, cell_h, layout.detail_x + PAD_X + 4, action_top + buttonHeight(cell_h) + ACTION_BUTTON_GAP + 2),
    );
    try std.testing.expectEqual(
        Hit.attach_copilot,
        interactionHitTest(session, 1000, 700, top, 0, 1000, cell_h, layout.detail_x + PAD_X + 4, action_top + (buttonHeight(cell_h) + ACTION_BUTTON_GAP) * 2 + 2),
    );
```

- [ ] **Step 2: Run the failing tests**

Run:

```bash
zig build test
```

Expected: FAIL because the new hit variants and `detailActionTop` are missing.

- [ ] **Step 3: Add hit variants, geometry, and hit-test routing**

At the top of `src/renderer/terminal_agents/sessions.zig`, add constants near `RESUME_BUTTON_W`:

```zig
const ACTION_BUTTON_W: f32 = 148;
const ACTION_BUTTON_GAP: f32 = 8;
```

Extend `pub const Hit`:

```zig
    download_raw,
    export_markdown,
    attach_copilot,
```

Add geometry helpers near `resumeButtonTop`:

```zig
fn detailActionTop(top: f32, cell_h: f32) f32 {
    return resumeButtonTop(top, cell_h) + buttonHeight(cell_h) + 10;
}

fn detailActionHit(layout: Layout, top: f32, cell_h: f32, mx: f32, my: f32) Hit {
    const left = layout.detail_x + PAD_X;
    const h = buttonHeight(cell_h);
    const w = @min(ACTION_BUTTON_W, @max(1.0, layout.detail_w - PAD_X * 2));
    const y0 = detailActionTop(top, cell_h);
    if (rectContains(mx, my, left, y0, w, h)) return .download_raw;
    if (rectContains(mx, my, left, y0 + h + ACTION_BUTTON_GAP, w, h)) return .export_markdown;
    if (rectContains(mx, my, left, y0 + (h + ACTION_BUTTON_GAP) * 2, w, h)) return .attach_copilot;
    return .none;
}
```

In `interactionHitTest`, after the resume-button hit-test block, add:

```zig
        const action_hit = detailActionHit(layout, top, cell_h, mx, my);
        if (action_hit != .none) return action_hit;
```

- [ ] **Step 4: Render the buttons and move transcript content below them**

In `renderDetail`, after rendering the Resume button, add:

```zig
    const action_top = detailActionTop(top, draw.cell_h);
    const action_h = buttonHeight(draw.cell_h);
    const action_w = @min(ACTION_BUTTON_W, @max(1.0, layout.detail_w - PAD_X * 2));
    const action_x = layout.detail_x + PAD_X;
    const action_labels = [_][]const u8{ "Download Raw", "Export Markdown", "Attach to Copilot" };
    for (action_labels, 0..) |label, i| {
        const row_top = action_top + @as(f32, @floatFromInt(i)) * (action_h + ACTION_BUTTON_GAP);
        draw.fillQuadAlpha(action_x, yFromTop(window_height, row_top, action_h), action_w, action_h, panel_strong, 0.72);
        _ = draw.renderTextLimited(label, action_x + 12, yTextFromTop(draw, window_height, row_top + BUTTON_PAD_Y), accent, action_w - 24);
    }

    y = action_top + (action_h + ACTION_BUTTON_GAP) * 3 + 12;
```

Leave the separator drawing immediately after that updated `y`.

- [ ] **Step 5: Run tests**

Run:

```bash
zig build test
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/renderer/terminal_agents/sessions.zig
git commit -m "feat: render ai history selected actions"
```

---

### Task 7: Wire AppWindow AI History Actions

**Files:**
- Modify: `src/AppWindow.zig`
- Modify: `src/source_guards/side_effect_guard.zig`

- [ ] **Step 1: Add imports and helper signatures**

In `src/AppWindow.zig`, add the export formatter import near the other AI History imports:

```zig
const ai_history_markdown = @import("terminal_agents/sessions/markdown.zig");
```

Add these function declarations by implementing them in Step 3:

```zig
pub fn aiHistoryDownloadSelectedRaw() bool
pub fn aiHistoryExportSelectedMarkdown() bool
pub fn aiHistoryAttachSelectedToCopilot() bool
```

- [ ] **Step 2: Write source-guard ratchet test expectation**

In `src/source_guards/side_effect_guard.zig`, change the AppWindow ceiling from `57` to `56`:

```zig
    .{ .name = "AppWindow.zig", .source = @embedFile("../AppWindow.zig"), .ceiling = 56 },
```

Run:

```bash
zig build test
```

Expected: FAIL because AppWindow still has 57 direct dirty-global writes.

- [ ] **Step 3: Lower the AppWindow side-effect ratchet**

In `copyAiChatMarkdown` in `src/AppWindow.zig`, replace:

```zig
        g_force_rebuild = true;
```

with:

```zig
        markUiDirty();
```

- [ ] **Step 4: Implement selected metadata and transcript loaders**

Add these helpers near `startAiHistoryTranscript`:

```zig
fn selectedAiHistoryMetaForAction(allocator: std.mem.Allocator, session: *ai_history_session.Session) ?ai_history_types.SessionMeta {
    return session.selectedMetadataClone(allocator);
}

fn loadAiHistoryTranscriptForAction(
    allocator: std.mem.Allocator,
    session: *ai_history_session.Session,
    meta: ai_history_types.SessionMeta,
) ?[]ai_history_types.TranscriptMessage {
    session.mutex.lock();
    if (session.transcript_state == .ready and session.transcript_provider != null and session.transcript_provider.? == meta.provider) {
        const cloned = cloneAiHistoryTranscriptMessages(allocator, session.transcript) catch null;
        session.mutex.unlock();
        return cloned;
    }
    session.mutex.unlock();

    const target = aiHistoryTargetSnapshot(session.source.target) orelse return null;
    const messages: []ai_history_types.TranscriptMessage = switch (target) {
        .local => ai_history_session.loadLocalTranscript(allocator, meta) catch return null,
        .wsl => blk: {
            var host_state = ai_history_session.WslScannerHost{};
            const host = host_state.scannerHost();
            break :blk host.loadTranscript(host.ctx, allocator, meta) catch return null;
        },
        .ssh => |conn| blk: {
            var host_state = ai_history_session.SshScannerHost{ .conn = conn };
            const host = host_state.scannerHost();
            break :blk host.loadTranscript(host.ctx, allocator, meta) catch return null;
        },
    };

    const preview_copy = cloneAiHistoryTranscriptMessages(allocator, messages) catch null;
    if (preview_copy) |copy| session.replaceTranscriptFromMessages(meta.provider, copy);
    return messages;
}

fn cloneAiHistoryTranscriptMessages(
    allocator: std.mem.Allocator,
    messages: []const ai_history_types.TranscriptMessage,
) ![]ai_history_types.TranscriptMessage {
    const cloned = try allocator.alloc(ai_history_types.TranscriptMessage, messages.len);
    var initialized: usize = 0;
    errdefer {
        while (initialized > 0) {
            initialized -= 1;
            allocator.free(cloned[initialized].content);
        }
        allocator.free(cloned);
    }
    for (messages) |msg| {
        cloned[initialized] = msg;
        cloned[initialized].content = try allocator.dupe(u8, msg.content);
        initialized += 1;
    }
    return cloned;
}
```

- [ ] **Step 5: Implement save path helpers**

Add these helpers near `saveMarkdownDialogPath`:

```zig
fn chooseAiHistoryMarkdownExportPath(
    allocator: std.mem.Allocator,
    meta: ai_history_types.SessionMeta,
) !?[]u8 {
    const root = try aiChatExportRoot(allocator);
    defer allocator.free(root);
    std.fs.cwd().makePath(root) catch |err| {
        log.warn("failed to create AI history export directory {s}: {}", .{ root, err });
    };
    var safe_buf: [180]u8 = undefined;
    const raw = ai_history_markdown.rawDownloadFilename(meta, &safe_buf);
    const filename = try std.fmt.allocPrint(allocator, "ai-history-{s}.md", .{std.fs.path.stem(raw)});
    defer allocator.free(filename);
    return saveMarkdownDialogPathWithTitle(allocator, "Save AI History Markdown", root, filename);
}

fn chooseAiHistoryRawDownloadPath(
    allocator: std.mem.Allocator,
    meta: ai_history_types.SessionMeta,
) !?[]u8 {
    const root = platform_dirs.downloadsDir(allocator) catch try aiChatExportRoot(allocator);
    defer allocator.free(root);
    var filename_buf: [180]u8 = undefined;
    const filename = ai_history_markdown.rawDownloadFilename(meta, &filename_buf);
    const filters = [_]platform_file_dialog.Filter{.{ .name = "All Files (*.*)", .pattern = "*.*" }};
    const owner: platform_file_dialog.Owner = if (g_window) |w|
        platform_file_dialog.windowOwner(window_backend.nativeHandleBits(w))
    else
        .{};
    return platform_file_dialog.saveFile(allocator, .{
        .owner = owner,
        .title = "Save AI History Raw File",
        .initial_dir = root,
        .default_filename = filename,
        .filters = &filters,
    }) orelse {
        overlays.showStatusToast("Raw download cancelled");
        return null;
    };
}
```

Then split the existing Markdown save helper so Copilot keeps its current title
and AI History gets its own title:

```zig
fn saveMarkdownDialogPath(
    allocator: std.mem.Allocator,
    initial_dir: []const u8,
    default_filename: []const u8,
) !?[]u8 {
    return saveMarkdownDialogPathWithTitle(allocator, "Save Copilot Markdown", initial_dir, default_filename);
}

fn saveMarkdownDialogPathWithTitle(
    allocator: std.mem.Allocator,
    title_text: []const u8,
    initial_dir: []const u8,
    default_filename: []const u8,
) !?[]u8 {
    const filters = [_]platform_file_dialog.Filter{
        .{ .name = "Markdown (*.md)", .pattern = "*.md" },
        .{ .name = "All Files (*.*)", .pattern = "*.*" },
    };
    const owner: platform_file_dialog.Owner = if (g_window) |w|
        platform_file_dialog.windowOwner(window_backend.nativeHandleBits(w))
    else
        .{};
    const path = platform_file_dialog.saveFile(allocator, .{
        .owner = owner,
        .title = title_text,
        .initial_dir = initial_dir,
        .default_filename = default_filename,
        .default_extension = "md",
        .filters = &filters,
    }) orelse {
        overlays.showStatusToast("Markdown export cancelled");
        return null;
    };
    return path;
}
```

- [ ] **Step 6: Implement raw read/write helpers**

Add:

```zig
fn readLocalAiHistoryRaw(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) {
        const file = try std.fs.openFileAbsolute(path, .{});
        defer file.close();
        return try file.readToEndAlloc(allocator, ai_history_session.MAX_METADATA_FILE_BYTES);
    }
    return try std.fs.cwd().readFileAlloc(allocator, path, ai_history_session.MAX_METADATA_FILE_BYTES);
}

fn readWslAiHistoryRaw(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var command_buf: [2048]u8 = undefined;
    const command = try ai_history_session.remoteCatCommand(path, command_buf[0..]);
    return remote_file.wslExec(allocator, command) orelse error.RemoteExecFailed;
}
```

- [ ] **Step 7: Implement the three public action entry points**

Add:

```zig
pub fn aiHistoryDownloadSelectedRaw() bool {
    const session = activeAiHistory() orelse return false;
    const allocator = g_allocator orelse return false;
    const meta = selectedAiHistoryMetaForAction(allocator, session) orelse {
        overlays.showStatusToast("No AI History session selected");
        markUiDirty();
        return true;
    };
    defer ai_history_session.freeMetadata(allocator, meta);

    const path = chooseAiHistoryRawDownloadPath(allocator, meta) catch {
        overlays.showStatusToast("Raw download failed");
        markUiDirty();
        return true;
    } orelse {
        markUiDirty();
        return true;
    };
    defer allocator.free(path);

    switch (session.source.target) {
        .local => {
            const bytes = readLocalAiHistoryRaw(allocator, meta.source_path) catch {
                overlays.showStatusToast("Raw download failed");
                markUiDirty();
                return true;
            };
            defer allocator.free(bytes);
            writeFilePath(path, bytes) catch {
                overlays.showStatusToast("Raw download failed");
                markUiDirty();
                return true;
            };
            _ = input.copyTextToClipboard(path);
            overlays.showStatusToast("Downloaded raw history; path copied");
        },
        .wsl => {
            const bytes = readWslAiHistoryRaw(allocator, meta.source_path) catch {
                overlays.showStatusToast("WSL raw download failed");
                markUiDirty();
                return true;
            };
            defer allocator.free(bytes);
            writeFilePath(path, bytes) catch {
                overlays.showStatusToast("Raw download failed");
                markUiDirty();
                return true;
            };
            _ = input.copyTextToClipboard(path);
            overlays.showStatusToast("Downloaded raw history; path copied");
        },
        .ssh => |ssh_ref| {
            const conn = overlays.aiHistorySshConnection(ssh_ref.profile_name) orelse {
                overlays.showStatusToast("SSH profile unavailable");
                markUiDirty();
                return true;
            };
            var filename_buf: [180]u8 = undefined;
            const filename = ai_history_markdown.rawDownloadFilename(meta, &filename_buf);
            _ = file_explorer.downloadRemotePathToPath(meta.source_path, path, filename, &conn, false);
        },
    }
    markUiDirty();
    return true;
}

pub fn aiHistoryExportSelectedMarkdown() bool {
    const session = activeAiHistory() orelse return false;
    const allocator = g_allocator orelse return false;
    const meta = selectedAiHistoryMetaForAction(allocator, session) orelse {
        overlays.showStatusToast("No AI History session selected");
        markUiDirty();
        return true;
    };
    defer ai_history_session.freeMetadata(allocator, meta);

    const messages = loadAiHistoryTranscriptForAction(allocator, session, meta) orelse {
        overlays.showStatusToast("Markdown export failed");
        markUiDirty();
        return true;
    };
    defer ai_history_session.freeTranscript(allocator, meta.provider, messages);

    const markdown = ai_history_markdown.allocMarkdownExport(allocator, meta, messages, .{}) catch {
        overlays.showStatusToast("Markdown export failed");
        markUiDirty();
        return true;
    };
    defer allocator.free(markdown);

    const path = chooseAiHistoryMarkdownExportPath(allocator, meta) catch {
        overlays.showStatusToast("Markdown export failed");
        markUiDirty();
        return true;
    } orelse {
        markUiDirty();
        return true;
    };
    defer allocator.free(path);

    writeFilePath(path, markdown) catch {
        overlays.showStatusToast("Markdown export failed");
        markUiDirty();
        return true;
    };
    _ = input.copyTextToClipboard(path);
    overlays.showStatusToast("Exported AI History Markdown; path copied");
    markUiDirty();
    return true;
}

pub fn aiHistoryAttachSelectedToCopilot() bool {
    const session = activeAiHistory() orelse return false;
    const allocator = g_allocator orelse return false;
    const meta = selectedAiHistoryMetaForAction(allocator, session) orelse {
        overlays.showStatusToast("No AI History session selected");
        markUiDirty();
        return true;
    };
    defer ai_history_session.freeMetadata(allocator, meta);

    const messages = loadAiHistoryTranscriptForAction(allocator, session, meta) orelse {
        overlays.showStatusToast("Attach failed");
        markUiDirty();
        return true;
    };
    defer ai_history_session.freeTranscript(allocator, meta.provider, messages);

    var context = ai_history_markdown.allocCopilotContext(allocator, meta, messages, 48 * 1024) catch {
        overlays.showStatusToast("Attach failed");
        markUiDirty();
        return true;
    };
    defer context.deinit(allocator);

    const target = ensureAiHistoryCopilotTarget() orelse {
        overlays.showStatusToast("Configure a Copilot profile first");
        markUiDirty();
        return true;
    };
    var title_buf: [160]u8 = undefined;
    const title_text = std.fmt.bufPrint(&title_buf, "AI History: {s} {s}", .{ meta.provider.label(), meta.session_id }) catch "AI History";
    target.appendContextCard(title_text, context.markdown, true) catch {
        overlays.showStatusToast("Attach failed");
        markUiDirty();
        return true;
    };
    overlays.showStatusToast(if (context.truncated) "Attached truncated AI History context" else "Attached AI History context");
    markUiDirty();
    return true;
}
```

- [ ] **Step 8: Implement Copilot target selection**

Add:

```zig
fn ensureAiHistoryCopilotTarget() ?*ai_chat.Session {
    if (activeAiChat()) |session| return session;
    if (activeCopilotSessionForInput()) |session| return session;
    const allocator = g_allocator orelse return null;
    const session = makeCopilotSession() orelse return null;
    if (!tab.spawnAiChatSession(allocator, session)) {
        session.deinit();
        return null;
    }
    clearUiStateOnTabChange();
    return activeAiChat();
}
```

- [ ] **Step 9: Route renderer hit variants**

In `aiHistoryHandleMousePress`, add cases:

```zig
        .download_raw => {
            _ = aiHistoryDownloadSelectedRaw();
            return true;
        },
        .export_markdown => {
            _ = aiHistoryExportSelectedMarkdown();
            return true;
        },
        .attach_copilot => {
            _ = aiHistoryAttachSelectedToCopilot();
            return true;
        },
```

- [ ] **Step 10: Run tests**

Run:

```bash
zig build test
```

Expected: PASS, including `side_effect_guard` with AppWindow ceiling `56`.

- [ ] **Step 11: Commit**

```bash
git add src/AppWindow.zig src/source_guards/side_effect_guard.zig
git commit -m "feat: implement ai history selected actions"
```

---

### Task 8: Add AI History Keyboard Shortcuts

**Files:**
- Modify: `src/input.zig`

- [ ] **Step 1: Add source-scan expectations for the new action routing**

In `src/test_fast.zig`, add this guard near the other input source-scan tests:

```zig
test "input routes AI History selected action shortcuts through AppWindow actions" {
    const source = @embedFile("input.zig");
    try std.testing.expect(std.mem.indexOf(u8, source, "aiHistoryDownloadSelectedRaw") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "aiHistoryExportSelectedMarkdown") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "aiHistoryAttachSelectedToCopilot") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "!search_focused") != null);
}
```

- [ ] **Step 2: Run the failing tests**

Run:

```bash
zig build test
```

Expected: FAIL because the action names are not present in `input.zig`.

- [ ] **Step 3: Route `D`, `M`, and `A` when search is not focused**

In the AI History key switch in `src/input.zig`, after the `0x52` (`R`) case, add:

```zig
            0x44 => if (plain and !ev.shift and !search_focused) {
                _ = AppWindow.aiHistoryDownloadSelectedRaw();
                return .none;
            },
            0x4D => if (plain and !ev.shift and !search_focused) {
                _ = AppWindow.aiHistoryExportSelectedMarkdown();
                return .none;
            },
            0x41 => if (plain and !ev.shift and !search_focused) {
                _ = AppWindow.aiHistoryAttachSelectedToCopilot();
                return .none;
            },
```

- [ ] **Step 4: Run tests**

Run:

```bash
zig build test
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/input.zig src/test_fast.zig
git commit -m "feat: add ai history action shortcuts"
```

---

### Task 9: Update User Documentation

**Files:**
- Modify: `README.md`
- Modify: `docs/ai-agent.md`

- [ ] **Step 1: Update README shortcut table**

In `README.md`, after the `Preview selected AI History transcript` row, add:

```markdown
| Download selected AI History raw file | **D** in AI History | **D** in AI History |
| Export selected AI History transcript as Markdown | **M** in AI History | **M** in AI History |
| Attach selected AI History transcript to Copilot | **A** in AI History | **A** in AI History |
```

- [ ] **Step 2: Update AI agent docs**

In `docs/ai-agent.md`, after the paragraph that starts `Use Resume to open a real terminal tab`, add:

```markdown
The selected history row also supports local handoff actions: press `D` to
download the provider's raw history file, `M` to export the parsed transcript as
Markdown, or `A` to attach the transcript as a collapsed Copilot context card
for a follow-up question.
```

- [ ] **Step 3: Run docs diff check**

Run:

```bash
git diff --check -- README.md docs/ai-agent.md
```

Expected: no output and exit code 0.

- [ ] **Step 4: Commit**

```bash
git add README.md docs/ai-agent.md
git commit -m "docs: document ai history selected actions"
```

---

### Task 10: Final Verification

**Files:**
- No source edits unless verification finds a defect.

- [ ] **Step 1: Run fast tests**

Run:

```bash
zig build test
```

Expected: PASS.

- [ ] **Step 2: Run full tests**

Run:

```bash
zig build test-full
```

Expected: PASS.

- [ ] **Step 3: Check Windows checkout safety only if files were added or renamed**

This plan adds `src/terminal_agents/sessions/markdown.zig` and this plan file. Run the path-safety checks documented in `docs/development.md#windows-checkout-safety`.

Expected: no reserved names, illegal characters, case-fold collisions, symlinks, or excessive path lengths.

- [ ] **Step 4: Final source-guard sanity**

Run:

```bash
zig build check-sizes
```

Expected: PASS.

- [ ] **Step 5: Inspect final status**

Run:

```bash
git status --short
```

Expected: only intentional changes are present.
