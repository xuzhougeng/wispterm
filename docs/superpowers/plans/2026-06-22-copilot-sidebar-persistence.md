# Copilot Sidebar Persistence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the per-terminal-tab Copilot sidebar conversation persistent — it survives app restart (restored in place), survives closing the terminal tab (retained in the store), and is retrievable from a keyboard-driven Copilot conversation picker reachable via `/resume`, the command center, and a dedicated shortcut.

**Architecture:** Reuse the existing `agent-history.json` store (`g_agent_history`) and its incremental-flush + quit-snapshot infrastructure unchanged. A new `copilot: bool` marker on `SessionRecord` distinguishes Copilot conversations from standalone AI-chat-tab conversations that share the one store. The terminal tab's `TabSnap` gains a `copilot_session_id` pointer (mirroring `ai_session_id`) plus a `copilot_visible` flag for restore-in-place. A new `copilot_picker.zig` overlay module (mirroring `jupyter_picker.zig`) lists `copilot == true` records; load/delete reduce to store lookups by id.

**Tech Stack:** Zig (terminal emulator). `std.json` for store/snapshot serialization. Existing thread-local tab model (`appwindow/tab.zig`), global history store + flush scheduler (`AppWindow.zig`), overlay render (`renderer/overlays.zig`), input routing (`input.zig`), command catalog (`command_center_state.zig`), keybinds (`keybind.zig`), i18n (`i18n.zig`).

---

## Spec

Source spec: [`docs/superpowers/specs/2026-06-22-copilot-sidebar-persistence-design.md`](../specs/2026-06-22-copilot-sidebar-persistence-design.md). This plan implements it.

## Scope notes

- **In scope (v1):** store marker; write paths (incremental hook, quit snapshot, snapshot id); restore-in-place; the Copilot conversation picker (state + render + input); load-by-id with de-dup; manual delete; `/resume` made context-aware in the sidebar; a command-center command; a dedicated keyboard shortcut.
- **Deliberately deferred to a follow-up (not v1):** the on-screen sidebar **"Past conversations" button**. The spec lists a sidebar button *plus* a keyboard shortcut as the sidebar entry point; v1 ships the keyboard shortcut + `/resume` (both usable from the focused sidebar) + the command-center command, which together satisfy "reachable from the sidebar, the command center, and `/resume`." The button is an on-screen affordance only and requires `ai_sidebar` layout work orthogonal to persistence. Adding it later reuses the same `loadCopilotConversationById` / picker trigger built here.
- **No retention cap** (manual delete only) — matches the spec's YAGNI stance.
- Copilot records never leak into the Sessions panel (inherent — Sessions scans external CLI dirs only) nor into the AI-chat-tab history picker (the `copilot` marker filters that).

## Test strategy (how this codebase tests)

Three test step targets exist (see `build.zig`):

- `zig build test` — fast native logic suite (`src/test_fast.zig`). Modules registered here: `agent_history.zig`, `ai_chat_composer.zig`, `command_center_state.zig`, `i18n.zig`, and any new pure module we add.
- `zig build test-full` — complete suite incl. the app test binary (`src/test_main.zig`). Required for `ai_chat.zig`, `session_persist.zig`, `AppWindow.zig` (these are NOT in the fast suite).
- The default `zig build` target is Windows-cross — do **not** use bare `zig build` to validate logic. Use the test steps above. (macOS app build, if needed for manual smoke, is `zig build macos-app -Dtarget=aarch64-macos`.)

Two test idioms are used below:

1. **Pure unit tests** — preferred. Construct values directly and assert (e.g. JSON round-trip, predicate truth tables, index clamping, relative-time formatting, branch selection).
2. **Source-embed tests** — for wiring that touches the live UI/window graph and can't be exercised headlessly, the repo asserts on source text via `@embedFile` + `std.mem.indexOf` (see existing examples in `src/test_fast.zig` and `src/build.zig`'s `expectSourceContains`). These are legitimate regression guards here, not placeholders. Use them only where a behavioral unit test is infeasible.

---

## File Structure

**New files:**

- `src/copilot_picker.zig` — thread-local picker state + pure helpers (`nextIndex`, `firstVisible`, `formatRelativeTime`, row label). One responsibility: hold and navigate the picker's row model. Mirrors `src/jupyter_picker.zig`. Registered in `test_fast.zig`.

**Modified files:**

- `src/agent_history.zig` — add `copilot: bool` to `SessionRecord`; propagate in `cloneRecord`; add `buildCopilotRows` (filtered row builder).
- `src/ai_chat.zig` — propagate `copilot` in `toHistoryRecordLocked` (write) and `initFromHistoryRecord` (read); add `shouldPersistCopilot` predicate; add `DeferredAction.copilot_conversation_picker` + `g_copilot_picker_trigger` + setter; branch `.resume_session` on `self.copilot`; context-aware `/resume` description.
- `src/session_persist.zig` — add `copilot_session_id` + `copilot_visible` to `TabSnap`.
- `src/appwindow/tab.zig` — install history hook in `activeCopilotSession`; set copilot fields in `snapshotTab`; restore them in `restoreTab` via new `g_copilot_restore_hook`; add `findCopilotTabBySessionId` / `switchToCopilotTabBySessionId`.
- `src/AppWindow.zig` — extend `persistOpenAiChatTabsToHistoryStore` to terminal copilot sessions; add + register `reopenCopilotSessionFromHistorySessionId` restore hook; add `loadCopilotConversationById` + `openCopilotConversationPicker`; register `g_copilot_picker_trigger`; `executeCommand` arm for the new command.
- `src/renderer/overlays.zig` — `renderCopilotPicker`; `executeCommand` arm.
- `src/input.zig` — picker key block; keybind dispatch arm.
- `src/command_center_state.zig` — `CommandAction.load_copilot_conversation` + catalog entry.
- `src/keybind.zig` — `Action.copilot_conversation_picker` + default binding.
- `src/i18n.zig` — picker strings + command title/detail translations.
- `src/test_fast.zig` — register `copilot_picker.zig`.

---

## Task 1: Store marker — `SessionRecord.copilot`

**Files:**
- Modify: `src/agent_history.zig:24-41` (struct), `src/agent_history.zig:212-254` (`cloneRecord`)
- Test: `src/agent_history.zig` (inline `test` blocks; runs under `zig build test`)

- [ ] **Step 1: Write the failing tests**

Append these `test` blocks at the end of `src/agent_history.zig` (after the existing tests near line 597+):

```zig
test "SessionRecord copilot flag round-trips through JSON" {
    const allocator = std.testing.allocator;
    var store = Store.init(allocator);
    defer store.deinit();

    try store.upsertRecord(.{
        .session_id = "copilot-1",
        .title = "T",
        .base_url = "https://x",
        .api_key = "k",
        .model = "m",
        .system_prompt = "s",
        .thinking_enabled = false,
        .reasoning_effort = "low",
        .stream = true,
        .agent_enabled = true,
        .created_at = 1,
        .updated_at = 2,
        .copilot = true,
        .messages = &[_]MessageRecord{},
    });

    const json = try store.toJsonString(allocator);
    defer allocator.free(json);

    var reloaded = try Store.fromJsonString(allocator, json);
    defer reloaded.deinit();
    try std.testing.expectEqual(@as(usize, 1), reloaded.records.items.len);
    try std.testing.expect(reloaded.records.items[0].copilot);
}

test "old record without copilot field defaults to false" {
    const allocator = std.testing.allocator;
    const json =
        \\{"records":[{"session_id":"old","title":"T","base_url":"u","api_key":"k",
        \\"model":"m","system_prompt":"s","thinking_enabled":false,"reasoning_effort":"low",
        \\"stream":true,"agent_enabled":true,"created_at":1,"updated_at":2,"messages":[]}]}
    ;
    var store = try Store.fromJsonString(allocator, json);
    defer store.deinit();
    try std.testing.expectEqual(@as(usize, 1), store.records.items.len);
    try std.testing.expect(!store.records.items[0].copilot);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test 2>&1 | tail -30`
Expected: FAIL — compile error `no field named 'copilot' in struct 'agent_history.SessionRecord'`.

- [ ] **Step 3: Add the field**

In `src/agent_history.zig`, add `copilot` to the struct (place it right after `vision_enabled` at line 38 so the default-bearing fields stay grouped):

```zig
pub const SessionRecord = struct {
    session_id: []const u8,
    title: []const u8,
    base_url: []const u8,
    api_key: []const u8,
    model: []const u8,
    protocol: []const u8 = DEFAULT_PROTOCOL,
    system_prompt: []const u8,
    thinking_enabled: bool,
    reasoning_effort: []const u8,
    stream: bool,
    max_tokens: u32 = 8192,
    agent_enabled: bool,
    vision_enabled: bool = false,
    copilot: bool = false,
    created_at: i64,
    updated_at: i64,
    messages: []MessageRecord,
};
```

- [ ] **Step 4: Propagate through `cloneRecord`**

In `src/agent_history.zig`, in the `return` literal of `cloneRecord` (currently ending at line 253), add a `copilot` line using the established `@hasField` back-compat idiom (so callers that pass a struct without the field still compile):

```zig
    return .{
        .session_id = session_id,
        .title = title,
        .base_url = base_url,
        .api_key = api_key,
        .model = model,
        .protocol = protocol,
        .system_prompt = system_prompt,
        .thinking_enabled = input.thinking_enabled,
        .reasoning_effort = reasoning_effort,
        .stream = input.stream,
        .max_tokens = if (@hasField(@TypeOf(input), "max_tokens")) input.max_tokens else 8192,
        .agent_enabled = input.agent_enabled,
        .vision_enabled = if (@hasField(@TypeOf(input), "vision_enabled")) input.vision_enabled else false,
        .copilot = if (@hasField(@TypeOf(input), "copilot")) input.copilot else false,
        .created_at = input.created_at,
        .updated_at = input.updated_at,
        .messages = messages,
    };
```

`freeOwnedRecord` needs no change (a `bool` owns no allocation).

- [ ] **Step 5: Run tests to verify they pass**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS (all fast-suite tests green).

- [ ] **Step 6: Commit**

```bash
git add src/agent_history.zig
git commit -m "feat(copilot): add copilot marker to SessionRecord"
```

---

## Task 2: Propagate `copilot` write/read in `ai_chat.zig`

**Files:**
- Modify: `src/ai_chat.zig:3987-4061` (`toHistoryRecordLocked` return literal), `src/ai_chat.zig:1034-1087` (`initFromHistoryRecord`)
- Test: `src/ai_chat.zig` (inline `test`; runs under `zig build test-full`)

- [ ] **Step 1: Write the failing test**

Add this `test` block to `src/ai_chat.zig` (near the other `Session` tests; if unsure, append at end of file):

```zig
test "copilot flag survives toHistoryRecord -> initFromHistoryRecord round-trip" {
    const allocator = std.testing.allocator;
    const session = try Session.init(
        allocator, "Copilot", "https://x", "k", "m",
        "sys", "disabled", "low", "true", "true",
    );
    defer session.deinit();
    session.copilot = true;

    var record = try session.toHistoryRecord(allocator);
    defer agent_history.freeOwnedRecord(allocator, &record);
    try std.testing.expect(record.copilot);

    const restored = try Session.initFromHistoryRecord(allocator, record);
    defer restored.deinit();
    try std.testing.expect(restored.copilot);
}
```

> Note: `Session.init(allocator, name, base_url, api_key, model, system_prompt, thinking, reasoning_effort, stream, agent_enabled)` is the existing constructor used elsewhere in this file. If the exact arity differs in your tree, mirror an existing `Session.init(...)` call already present in `ai_chat.zig`'s tests rather than guessing.

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test-full 2>&1 | tail -30`
Expected: FAIL — `restored.copilot` is `false` (and `record.copilot` may be `false`), assertions trip.

- [ ] **Step 3: Write path — set `copilot` in `toHistoryRecordLocked`**

In `src/ai_chat.zig`, in the `return` literal of `toHistoryRecordLocked` (ends ~line 4060), add `.copilot = self.copilot,` right after `.vision_enabled = self.vision_enabled,`:

```zig
        .agent_enabled = self.agent_enabled,
        .vision_enabled = self.vision_enabled,
        .copilot = self.copilot,
        .created_at = self.created_at_ms,
        .updated_at = self.updated_at_ms,
        .messages = messages,
    };
```

- [ ] **Step 4: Read path — set `copilot` in `initFromHistoryRecord`**

In `src/ai_chat.zig`, inside `initFromHistoryRecord`, under the existing `session.mutex.lock(); defer session.mutex.unlock();` block (right after `session.vision_enabled = record.vision_enabled;`, ~line 1053), add:

```zig
    session.max_tokens = record.max_tokens;
    session.vision_enabled = record.vision_enabled;
    session.copilot = record.copilot;
```

- [ ] **Step 5: Run test to verify it passes**

Run: `zig build test-full 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/ai_chat.zig
git commit -m "feat(copilot): persist and rehydrate Session.copilot via history record"
```

---

## Task 3: `shouldPersistCopilot` predicate

**Files:**
- Modify: `src/ai_chat.zig` (add public method on `Session`, near `toHistoryRecord` ~line 1402)
- Test: `src/ai_chat.zig` (inline `test`; `zig build test-full`)

A pure-ish predicate: a Copilot sidebar is worth persisting iff it has ≥1 persistable message. Mirror the `persist_to_history` count loop already in `toHistoryRecordLocked`.

- [ ] **Step 1: Write the failing test**

Add to `src/ai_chat.zig`:

```zig
test "shouldPersistCopilot is false for empty session, true after a real message" {
    const allocator = std.testing.allocator;
    const session = try Session.init(
        allocator, "Copilot", "https://x", "k", "m",
        "sys", "disabled", "low", "true", "true",
    );
    defer session.deinit();
    try std.testing.expect(!session.shouldPersistCopilot());

    {
        session.mutex.lock();
        defer session.mutex.unlock();
        try session.messages.append(allocator, .{
            .role = .user,
            .content = try allocator.dupe(u8, "hello"),
        });
    }
    try std.testing.expect(session.shouldPersistCopilot());
}
```

> If `Message` requires more fields than `.role`/`.content` in your tree, copy the minimal `Message{...}` literal already used in `initFromHistoryRecord` (it sets `.role` and `.content`, leaving the rest default).

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test-full 2>&1 | tail -30`
Expected: FAIL — `no member named 'shouldPersistCopilot'`.

- [ ] **Step 3: Implement the predicate**

In `src/ai_chat.zig`, next to the public `toHistoryRecord` wrapper (~line 1402), add:

```zig
/// True iff this session has at least one message that would be written to the
/// history store. Used to skip persisting/snapshotting never-chatted Copilot
/// sidebars (Issue: copilot-sidebar-persistence).
pub fn shouldPersistCopilot(self: *Session) bool {
    self.mutex.lock();
    defer self.mutex.unlock();
    for (self.messages.items) |msg| {
        if (msg.persist_to_history) return true;
    }
    return false;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test-full 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/ai_chat.zig
git commit -m "feat(copilot): add shouldPersistCopilot predicate"
```

---

## Task 4: `TabSnap` snapshot fields

**Files:**
- Modify: `src/session_persist.zig:69-80` (`TabSnap`)
- Test: `src/session_persist.zig` (inline `test`; `zig build test-full`)

- [ ] **Step 1: Write the failing tests**

Add to `src/session_persist.zig` (after the existing tests; this file already round-trips `Session` via `std.json`):

```zig
test "TabSnap copilot fields round-trip through JSON" {
    const allocator = std.testing.allocator;
    const snap = TabSnap{
        .tree = .{ .leaf = .{ .surface = .{ .local_shell = .{} } } },
        .copilot_session_id = "copilot-7",
        .copilot_visible = true,
    };
    const json = try std.json.Stringify.valueAlloc(allocator, snap, .{});
    defer allocator.free(json);

    const parsed = try std.json.parseFromSlice(TabSnap, allocator, json, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("copilot-7", parsed.value.copilot_session_id.?);
    try std.testing.expect(parsed.value.copilot_visible);
}

test "old TabSnap without copilot fields parses to null/false" {
    const allocator = std.testing.allocator;
    const json =
        \\{"tree":{"leaf":{"surface":{"local_shell":{}}}}}
    ;
    const parsed = try std.json.parseFromSlice(TabSnap, allocator, json, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(?[]const u8, null), parsed.value.copilot_session_id);
    try std.testing.expect(!parsed.value.copilot_visible);
}
```

> The `tree` literal must match `NodeSnap`'s actual shape. `snapshotTab` in `appwindow/tab.zig` constructs exactly `.{ .leaf = .{ .surface = .{ .local_shell = .{} } } }` for placeholder tabs — copy that form verbatim. Adjust only if `NodeSnap` differs in your tree.

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test-full 2>&1 | tail -30`
Expected: FAIL — `no field named 'copilot_session_id' in struct 'session_persist.TabSnap'`.

- [ ] **Step 3: Add the fields**

In `src/session_persist.zig`, extend `TabSnap` (after `ai_session_id` / `ai_history`):

```zig
pub const TabSnap = struct {
    title_override: ?[]const u8 = null,
    focused_leaf: u32 = 0,
    zoomed_leaf: ?u32 = null,
    tree: NodeSnap,
    ai_session_id: ?[]const u8 = null,
    ai_history: ?AiHistorySnap = null,
    // Active Copilot sidebar conversation for a `.terminal` tab. The conversation
    // lives in the agent-history store; this only points at it (mirrors
    // `ai_session_id`). Null in older snapshots → no Copilot conversation.
    copilot_session_id: ?[]const u8 = null,
    // Whether the Copilot sidebar was open when snapshotted. False in older
    // snapshots → sidebar starts collapsed (conversation still loaded).
    copilot_visible: bool = false,
};
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test-full 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/session_persist.zig
git commit -m "feat(copilot): add copilot_session_id/copilot_visible to TabSnap"
```

---

## Task 5: Write paths in `tab.zig` — incremental hook + snapshot id

**Files:**
- Modify: `src/appwindow/tab.zig:262-271` (`activeCopilotSession`), `src/appwindow/tab.zig:1445-1475` (`snapshotTab` terminal return)
- Test: `src/test_main.zig` source-embed guard (these touch the thread-local tab graph; behavior is covered end-to-end by Task 7's round-trip test)

- [ ] **Step 1: Write the failing source-embed guards**

Add to `src/test_main.zig` (it already uses `@embedFile` guards, e.g. the `session_persist` NTFS check ~line 435):

```zig
test "activeCopilotSession installs the history-change hook" {
    const src = @embedFile("appwindow/tab.zig");
    const anchor = "t.copilot_session = make() orelse return null;";
    const idx = std.mem.indexOf(u8, src, anchor) orelse return error.AnchorMissing;
    // The hook must be installed on the freshly-made copilot session.
    try std.testing.expect(std.mem.indexOf(u8, src[idx..], "installAiChatHistoryHook(") != null);
}

test "snapshotTab records copilot_session_id for terminal tabs" {
    const src = @embedFile("appwindow/tab.zig");
    try std.testing.expect(std.mem.indexOf(u8, src, ".copilot_session_id = ") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "shouldPersistCopilot()") != null);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test-full 2>&1 | tail -30`
Expected: FAIL — anchors for the hook install / `.copilot_session_id =` not found.

- [ ] **Step 3: Install the hook in `activeCopilotSession`**

In `src/appwindow/tab.zig`, update `activeCopilotSession` (lines 262-271) so a newly-created Copilot session gets the same history-change hook as AI-chat tabs:

```zig
pub fn activeCopilotSession(
    make: *const fn () ?*ai_chat.Session,
) ?*ai_chat.Session {
    const t = activeTab() orelse return null;
    if (t.kind != .terminal) return null;
    if (t.copilot_session == null) {
        t.copilot_session = make() orelse return null;
        // Wire incremental persistence: each completed turn now upserts this
        // conversation into the agent-history store (same path as AI-chat tabs).
        installAiChatHistoryHook(t.copilot_session.?);
    }
    return t.copilot_session;
}
```

`installAiChatHistoryHook` already exists at line 764 in this same file (private), so no import needed.

- [ ] **Step 4: Set copilot fields in `snapshotTab`**

In `src/appwindow/tab.zig`, in `snapshotTab`, the terminal-tab path builds `tree`/`focused_leaf`/`zoomed_leaf` and returns a `TabSnap` (the final `return` ~line 1469). Replace that final return with one that captures the copilot conversation:

```zig
    // Capture the active Copilot sidebar conversation (if worth persisting) so
    // it can be restored in place. The conversation itself is in the store.
    var copilot_sid: ?[]const u8 = null;
    if (t.copilot_session) |cs| {
        if (cs.shouldPersistCopilot()) copilot_sid = try arena.dupe(u8, cs.sessionId());
    }

    return session_persist.TabSnap{
        .title_override = try snapshotFocusedTitleOverride(arena, t),
        .focused_leaf = focused_leaf,
        .zoomed_leaf = zoomed_leaf,
        .tree = tree,
        .copilot_session_id = copilot_sid,
        .copilot_visible = if (copilot_sid != null) t.copilot_visible else false,
    };
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `zig build test-full 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/appwindow/tab.zig src/test_main.zig
git commit -m "feat(copilot): install history hook + snapshot copilot session id"
```

---

## Task 6: Quit snapshot — extend `persistOpenAiChatTabsToHistoryStore`

**Files:**
- Modify: `src/AppWindow.zig:5234-5257`
- Test: `src/AppWindow.zig` (extend the existing test at ~line 1090; `zig build test-full`)

- [ ] **Step 1: Write the failing test**

There is already a test `"AppWindow: open AI chat tabs are persisted to agent history before session dump"` (~line 1090) that drives `persistOpenAiChatTabsToHistoryStore`. Add a sibling test (place it right after that one) that builds a `.terminal` tab with a non-empty `copilot_session` and asserts it lands in the store. Model the tab/store setup on the existing test verbatim; the new assertions are:

```zig
test "AppWindow: open terminal copilot sessions are persisted before session dump" {
    // ... mirror the setup of the existing AI-chat persistence test:
    //   - init a Store, set g_agent_history = &store under the mutex
    //   - create a TabState{ .kind = .terminal } in tab.g_tabs[0], g_tab_count = 1
    //   - make a copilot session (Session.init(...)), set session.copilot = true,
    //     append one user message so shouldPersistCopilot() is true,
    //     assign tab.copilot_session = session
    // Then:
    persistOpenAiChatTabsToHistoryStore(std.testing.allocator);

    g_agent_history_mutex.lock();
    defer g_agent_history_mutex.unlock();
    const store = g_agent_history.?;
    try std.testing.expect(store.findIndexBySessionId(session.sessionId()) != null);
    try std.testing.expect(store.records.items[0].copilot);
}
```

> Copy the exact store/tab teardown (`defer`) from the existing test so allocations are freed. `findIndexBySessionId` is private to `Store`; if it isn't reachable from this test scope, assert via `(try store.buildRows(alloc)).len == 1` + `freeRows` instead.

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test-full 2>&1 | tail -30`
Expected: FAIL — the terminal tab's copilot session is not persisted (store has no matching record).

- [ ] **Step 3: Extend the function**

In `src/AppWindow.zig`, rewrite the head of the loop in `persistOpenAiChatTabsToHistoryStore` (lines 5235-5238) to resolve the session-to-persist from either tab kind, keeping the rest of the body unchanged:

```zig
fn persistOpenAiChatTabsToHistoryStore(allocator: std.mem.Allocator) void {
    for (0..tab.g_tab_count) |idx| {
        const tab_state = tab.g_tabs[idx] orelse continue;
        const session: *ai_chat.Session = switch (tab_state.kind) {
            .ai_chat => tab_state.ai_chat_session orelse continue,
            .terminal => blk: {
                const cs = tab_state.copilot_session orelse continue;
                if (!cs.shouldPersistCopilot()) continue;
                break :blk cs;
            },
            else => continue,
        };

        var record = session.toHistoryRecord(allocator) catch |err| {
            log.warn("failed to snapshot open AI tab for session restore: {}", .{err});
            continue;
        };
        // ... existing lock/upsert/markDirty/free body unchanged ...
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test-full 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/AppWindow.zig
git commit -m "feat(copilot): persist terminal copilot sessions at quit"
```

---

## Task 7: Restore in place — restore hook + plumbing

**Files:**
- Modify: `src/appwindow/tab.zig` (declare `g_copilot_restore_hook` near line 180; use it in `restoreTab` ~line 1717-1730)
- Modify: `src/AppWindow.zig` (add `reopenCopilotSessionFromHistorySessionId`; register near line 5196-5197)
- Test: `src/test_main.zig` (end-to-end snapshot→restore round-trip; `zig build test-full`)

- [ ] **Step 1: Write the failing test**

Add to `src/test_main.zig` an end-to-end guard that exercises store→restore-hook→session. Build a Store with one `copilot == true` record, install `tab.g_copilot_restore_hook`, and assert the hook rehydrates a session with `copilot == true`:

```zig
test "copilot restore hook rehydrates a copilot session by id" {
    const std = @import("std");
    const tab = @import("appwindow/tab.zig");
    const ai_chat = @import("ai_chat.zig");
    const AppWindow = @import("AppWindow.zig");
    const agent_history = @import("agent_history.zig");
    const allocator = std.testing.allocator;

    var store = agent_history.Store.init(allocator);
    defer store.deinit();
    try store.upsertRecord(.{
        .session_id = "cp-restore",
        .title = "T", .base_url = "https://x", .api_key = "k", .model = "m",
        .system_prompt = "s", .thinking_enabled = false, .reasoning_effort = "low",
        .stream = true, .agent_enabled = true, .created_at = 1, .updated_at = 2,
        .copilot = true, .messages = &[_]agent_history.MessageRecord{},
    });

    AppWindow.installAgentHistoryStoreForTest(&store); // sets g_agent_history under mutex
    defer AppWindow.clearAgentHistoryStoreForTest();
    AppWindow.installCopilotRestoreHookForTest(); // sets tab.g_copilot_restore_hook
    defer { tab.g_copilot_restore_hook = null; }

    const hook = tab.g_copilot_restore_hook.?;
    const session = hook("cp-restore") orelse return error.RestoreFailed;
    defer session.deinit();
    try std.testing.expect(session.copilot);
    try std.testing.expectEqualStrings("cp-restore", session.sessionId());
}
```

> The `installAgentHistoryStoreForTest` / `clearAgentHistoryStoreForTest` / `installCopilotRestoreHookForTest` helpers are tiny test shims you add in Step 4 (the globals are file-private to `AppWindow.zig`, so they need an in-file accessor). If the existing AI-chat persistence test already sets `g_agent_history` via some helper, reuse that pattern instead of adding new shims.

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test-full 2>&1 | tail -30`
Expected: FAIL — `g_copilot_restore_hook` undeclared / helper missing.

- [ ] **Step 3: Declare the hook and use it in `restoreTab` (tab.zig)**

In `src/appwindow/tab.zig`, next to the existing restore-hook globals (after line 186), declare:

```zig
/// Rehydrates a Copilot sidebar conversation from the agent-history store by id,
/// returning an owned `*ai_chat.Session` (with the history hook installed) or
/// null if the record is gone. AppWindow installs this (it owns the store).
pub threadlocal var g_copilot_restore_hook: ?*const fn (session_id: []const u8) ?*ai_chat.Session = null;
```

Then in `restoreTab`, in the `.terminal` branch after the existing `t.copilot_session = null;` / `t.copilot_visible = false;` initializations (~lines 1722-1730, before `applyRestoredTabMetadata`), add the restore-in-place step:

```zig
    t.copilot_session = null;
    t.copilot_visible = false;
    // Restore the Copilot sidebar conversation in place, if any. Missing record
    // (deleted / corrupt store) → silent fallback to an empty sidebar.
    if (snap.copilot_session_id) |sid| {
        if (g_copilot_restore_hook) |hook| {
            if (hook(sid)) |session| {
                t.copilot_session = session;
                t.copilot_visible = snap.copilot_visible;
            }
        }
    }
    applyRestoredTabMetadata(t, snap);
```

- [ ] **Step 4: Implement and register the hook (AppWindow.zig)**

In `src/AppWindow.zig`, add the restore function (near `reopenAiChatTabFromHistorySessionId`, ~line 5180):

```zig
fn reopenCopilotSessionFromHistorySessionId(session_id: []const u8) ?*ai_chat.Session {
    const allocator = g_allocator orelse return null;

    var maybe_record: ?agent_history.SessionRecord = blk: {
        g_agent_history_mutex.lock();
        defer g_agent_history_mutex.unlock();
        const store = g_agent_history orelse break :blk null;
        break :blk store.cloneRecordBySessionId(allocator, session_id) catch null;
    };
    var record = maybe_record orelse return null;
    defer agent_history.freeOwnedRecord(allocator, &record);

    const session = ai_chat.Session.initFromHistoryRecord(allocator, record) catch return null;
    // initFromHistoryRecord set session.copilot from the record marker; wire the
    // same incremental-save hook AI-chat tabs use so future turns keep persisting.
    session.setHistoryChangeHook(saveAiHistoryChangeEvent);
    return session;
}
```

Register it next to the existing hook registrations (lines 5196-5197):

```zig
    tab.g_ai_restore_hook = reopenAiChatTabFromHistorySessionId;
    tab.g_ai_history_restore_hook = reopenAiHistoryTabFromSnapshot;
    tab.g_copilot_restore_hook = reopenCopilotSessionFromHistorySessionId;
```

Add the test shims (gate behind `builtin.is_test` or just leave them `pub` — they only touch existing globals):

```zig
pub fn installAgentHistoryStoreForTest(store: *agent_history.Store) void {
    g_agent_history_mutex.lock();
    defer g_agent_history_mutex.unlock();
    g_agent_history = store;
}
pub fn clearAgentHistoryStoreForTest() void {
    g_agent_history_mutex.lock();
    defer g_agent_history_mutex.unlock();
    g_agent_history = null;
}
pub fn installCopilotRestoreHookForTest() void {
    tab.g_copilot_restore_hook = reopenCopilotSessionFromHistorySessionId;
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `zig build test-full 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/appwindow/tab.zig src/AppWindow.zig src/test_main.zig
git commit -m "feat(copilot): restore copilot sidebar conversation in place"
```

---

## Task 8: `copilot_picker.zig` module + `buildCopilotRows`

**Files:**
- Create: `src/copilot_picker.zig`
- Modify: `src/agent_history.zig` (add `buildCopilotRows`)
- Modify: `src/test_fast.zig` (register the new module)
- Test: inline in `src/copilot_picker.zig` and `src/agent_history.zig` (`zig build test`)

- [ ] **Step 1: Write the failing tests**

Add to `src/agent_history.zig`:

```zig
test "buildCopilotRows lists only copilot records, newest first" {
    const allocator = std.testing.allocator;
    var store = Store.init(allocator);
    defer store.deinit();
    const base = SessionRecord{
        .session_id = "", .title = "", .base_url = "u", .api_key = "k", .model = "m",
        .system_prompt = "s", .thinking_enabled = false, .reasoning_effort = "low",
        .stream = true, .agent_enabled = true, .created_at = 0, .updated_at = 0,
        .messages = &[_]MessageRecord{},
    };
    var a = base; a.session_id = "a"; a.title = "A"; a.updated_at = 10; a.copilot = true;
    var b = base; b.session_id = "b"; b.title = "B"; b.updated_at = 20; b.copilot = true;
    var c = base; c.session_id = "c"; c.title = "C"; c.updated_at = 99; c.copilot = false;
    try store.upsertRecord(a);
    try store.upsertRecord(b);
    try store.upsertRecord(c);

    const rows = try store.buildCopilotRows(allocator);
    defer freeRows(allocator, rows);
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqualStrings("b", rows[0].session_id); // newest (20) first
    try std.testing.expectEqualStrings("a", rows[1].session_id);
}
```

Create `src/copilot_picker.zig` with these tests (and the implementation in Steps 3-4):

```zig
const std = @import("std");

test "nextIndex clamps to [0, n)" {
    try std.testing.expectEqual(@as(usize, 0), nextIndex(0, -1, 3));
    try std.testing.expectEqual(@as(usize, 2), nextIndex(2, 1, 3));
    try std.testing.expectEqual(@as(usize, 1), nextIndex(0, 1, 3));
    try std.testing.expectEqual(@as(usize, 0), nextIndex(0, 1, 0));
}

test "formatRelativeTime buckets" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("just now", formatRelativeTime(1000, 1000, &buf));
    try std.testing.expectEqualStrings("just now", formatRelativeTime(40_000, 0, &buf)); // 40s
    try std.testing.expectEqualStrings("5m ago", formatRelativeTime(5 * 60_000, 0, &buf));
    try std.testing.expectEqualStrings("3h ago", formatRelativeTime(3 * 3_600_000, 0, &buf));
    try std.testing.expectEqualStrings("2d ago", formatRelativeTime(2 * 86_400_000, 0, &buf));
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test 2>&1 | tail -30`
Expected: FAIL — `buildCopilotRows` undeclared; `copilot_picker.zig` not yet imported (after Step 4 wiring) or `nextIndex`/`formatRelativeTime` undefined.

- [ ] **Step 3: Add `buildCopilotRows` to the store**

In `src/agent_history.zig`, add after `buildRows` (line 117):

```zig
/// Like `buildRows` but only `copilot == true` records (the Copilot conversation
/// picker). Owned slices; call `freeRows()` when done. Sorted newest-first.
pub fn buildCopilotRows(self: *const Store, allocator: std.mem.Allocator) ![]Row {
    var list = std.ArrayListUnmanaged(Row){};
    errdefer {
        for (list.items) |*r| freeOwnedRow(allocator, r);
        list.deinit(allocator);
    }
    for (self.records.items) |record| {
        if (!record.copilot) continue;
        const row = try cloneRow(allocator, .{
            .session_id = record.session_id,
            .title = record.title,
            .model = record.model,
            .updated_at = record.updated_at,
        });
        try list.append(allocator, row);
    }
    const rows = try list.toOwnedSlice(allocator);
    sortRows(rows);
    return rows;
}
```

> `cloneRow`, `freeOwnedRow`, `freeRows`, `sortRows`, and `Row` already exist in this file. If `cloneRow`/`freeOwnedRow` are private, they're in the same file so the new method can call them.

- [ ] **Step 4: Implement `copilot_picker.zig` and register it**

Create `src/copilot_picker.zig` (the test blocks from Step 1 go at the bottom):

```zig
//! Thread-local state for the Copilot conversation picker overlay. Mirrors
//! `jupyter_picker.zig`: a keyboard-navigable list of past Copilot conversations
//! (title + relative time). Rows are populated from the agent-history store by
//! AppWindow (which owns the store); this module stays UI- and store-free.
const std = @import("std");

pub const MAX_ROWS = 64;
const MAX_ID_BYTES = 128;
const MAX_TITLE_BYTES = 256;

pub const Row = struct {
    session_id: []const u8,
    title: []const u8,
    updated_at: i64,
};

threadlocal var g_visible: bool = false;
threadlocal var g_id_bufs: [MAX_ROWS][MAX_ID_BYTES]u8 = undefined;
threadlocal var g_id_lens: [MAX_ROWS]usize = [_]usize{0} ** MAX_ROWS;
threadlocal var g_title_bufs: [MAX_ROWS][MAX_TITLE_BYTES]u8 = undefined;
threadlocal var g_title_lens: [MAX_ROWS]usize = [_]usize{0} ** MAX_ROWS;
threadlocal var g_updated: [MAX_ROWS]i64 = [_]i64{0} ** MAX_ROWS;
threadlocal var g_count: usize = 0;
threadlocal var g_selected: usize = 0;

pub fn isVisible() bool {
    return g_visible;
}
pub fn count() usize {
    return g_count;
}
/// Total selectable rows = conversations + the trailing "+ New conversation" row.
pub fn rowCount() usize {
    return g_count + 1;
}
pub fn selectedIndex() usize {
    return g_selected;
}
pub fn isNewRowSelected() bool {
    return g_selected == g_count;
}
pub fn idAt(idx: usize) []const u8 {
    if (idx >= g_count) return "";
    return g_id_bufs[idx][0..g_id_lens[idx]];
}
pub fn titleAt(idx: usize) []const u8 {
    if (idx >= g_count) return "";
    return g_title_bufs[idx][0..g_title_lens[idx]];
}
pub fn updatedAt(idx: usize) i64 {
    if (idx >= g_count) return 0;
    return g_updated[idx];
}
pub fn selectedId() []const u8 {
    return idAt(g_selected);
}

pub fn show(rows: []const Row) void {
    g_count = @min(rows.len, MAX_ROWS);
    for (0..g_count) |i| {
        const id_len = @min(rows[i].session_id.len, MAX_ID_BYTES);
        @memcpy(g_id_bufs[i][0..id_len], rows[i].session_id[0..id_len]);
        g_id_lens[i] = id_len;
        const t_len = @min(rows[i].title.len, MAX_TITLE_BYTES);
        @memcpy(g_title_bufs[i][0..t_len], rows[i].title[0..t_len]);
        g_title_lens[i] = t_len;
        g_updated[i] = rows[i].updated_at;
    }
    g_selected = 0;
    g_visible = true;
}

pub fn move(delta: i32) void {
    g_selected = nextIndex(g_selected, delta, rowCount());
}

pub fn hide() void {
    g_visible = false;
    g_count = 0;
    g_selected = 0;
}

pub fn nextIndex(selected: usize, delta: i32, n: usize) usize {
    if (n == 0) return 0;
    const ni: i64 = @as(i64, @intCast(selected)) + delta;
    const last: i64 = @as(i64, @intCast(n)) - 1;
    if (ni < 0) return 0;
    if (ni > last) return @intCast(last);
    return @intCast(ni);
}

pub fn firstVisible(selected: usize, visible_rows: usize, n: usize) usize {
    if (visible_rows == 0 or n <= visible_rows) return 0;
    const sel = @min(selected, n - 1);
    if (sel < visible_rows) return 0;
    return @min(sel - visible_rows + 1, n - visible_rows);
}

/// Short English relative-time label ("just now", "5m ago", "3h ago", "2d ago",
/// "4mo ago", "1y ago"). `now_ms`/`then_ms` are epoch milliseconds. Pure.
pub fn formatRelativeTime(now_ms: i64, then_ms: i64, buf: []u8) []const u8 {
    const diff = now_ms - then_ms;
    if (diff < 60_000) return "just now";
    const min = @divTrunc(diff, 60_000);
    if (min < 60) return std.fmt.bufPrint(buf, "{d}m ago", .{min}) catch "just now";
    const hr = @divTrunc(min, 60);
    if (hr < 24) return std.fmt.bufPrint(buf, "{d}h ago", .{hr}) catch "just now";
    const days = @divTrunc(hr, 24);
    if (days < 30) return std.fmt.bufPrint(buf, "{d}d ago", .{days}) catch "just now";
    const months = @divTrunc(days, 30);
    if (months < 12) return std.fmt.bufPrint(buf, "{d}mo ago", .{months}) catch "just now";
    const years = @divTrunc(days, 365);
    return std.fmt.bufPrint(buf, "{d}y ago", .{years}) catch "just now";
}
```

Register it in `src/test_fast.zig` inside the big `test { ... }` block (next to `_ = @import("jupyter_detect.zig");` or near the other pickers):

```zig
    _ = @import("copilot_picker.zig");
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/copilot_picker.zig src/agent_history.zig src/test_fast.zig
git commit -m "feat(copilot): add copilot_picker state module + buildCopilotRows"
```

---

## Task 9: Picker render + input wiring

**Files:**
- Modify: `src/renderer/overlays.zig` (add `renderCopilotPicker`; call it from the overlay render dispatch alongside `renderJupyterPicker`)
- Modify: `src/input.zig` (add the picker key block alongside the `jupyter_picker.isVisible()` block ~line 2749; add to `anyBlockingOverlayVisible` consideration if needed)
- Test: `src/test_main.zig` source-embed guards (rendering/input touch the live window graph)

- [ ] **Step 1: Write the failing source-embed guards**

Add to `src/test_main.zig`:

```zig
test "copilot picker is rendered and key-routed" {
    const overlays_src = @embedFile("renderer/overlays.zig");
    try std.testing.expect(std.mem.indexOf(u8, overlays_src, "pub fn renderCopilotPicker(") != null);
    const input_src = @embedFile("input.zig");
    try std.testing.expect(std.mem.indexOf(u8, input_src, "copilot_picker.isVisible()") != null);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test-full 2>&1 | tail -30`
Expected: FAIL — neither symbol present.

- [ ] **Step 3: Add `renderCopilotPicker` (overlays.zig)**

In `src/renderer/overlays.zig`, add the import near the other picker import (`const jupyter_picker = @import("../jupyter_picker.zig");`):

```zig
const copilot_picker = @import("../copilot_picker.zig");
```

Add the render function, adapted from `renderJupyterPicker` (lines 1429-1497). It draws the title + a row per conversation (`title` left, relative time right) + a trailing "+ New conversation" row:

```zig
/// Render the Copilot conversation picker overlay (mirror of renderJupyterPicker).
pub fn renderCopilotPicker(window_width: f32, window_height: f32) void {
    if (!copilot_picker.isVisible()) return;
    const total = copilot_picker.rowCount(); // conversations + "+ New" row
    if (total == 0) return;

    const bg = AppWindow.g_theme.background;
    const fg = AppWindow.g_theme.foreground;
    const accent = AppWindow.g_theme.cursor_color;
    const panel = mixColor(bg, fg, 0.05);
    const border = mixColor(bg, fg, 0.18);
    const sel_bg = mixColor(bg, accent, 0.5);
    const text_color = mixColor(bg, fg, 0.88);
    const meta_color = mixColor(bg, fg, 0.54);

    const row_h: f32 = @max(28.0, font.g_titlebar_cell_height + 12);
    const box_w: f32 = @min(window_width - 80, 720);
    const title_h: f32 = row_h;
    const bottom_pad: f32 = 16;
    const usable_h = @max(row_h, window_height - 32.0 - title_h - bottom_pad);
    const fit: usize = @intFromFloat(@max(1.0, @floor(usable_h / row_h)));
    const visible = @min(total, fit);
    const scroll = copilot_picker.firstVisible(copilot_picker.selectedIndex(), visible, total);
    const box_h: f32 = clampOverlayBoxHeight(title_h + row_h * @as(f32, @floatFromInt(visible)) + bottom_pad, window_height);
    const box_x = @round((window_width - box_w) / 2);
    const box_top = @round(@max(16.0, (window_height - box_h) / 2));
    const box_y = @round(window_height - box_top - box_h);

    ui_pipeline.fillQuadAlpha(0, 0, window_width, window_height, .{ 0.0, 0.0, 0.0 }, 0.30);
    renderRoundedQuadAlpha(box_x - 1, box_y - 1, box_w + 2, box_h + 2, 9, border, 0.5);
    renderRoundedQuadAlpha(box_x, box_y, box_w, box_h, 8, panel, 0.99);

    const title_y = @round(box_y + box_h - title_h + (title_h - font.g_titlebar_cell_height) / 2);
    _ = titlebar.renderTextLimited(i18n.s().copilot_picker_title, box_x + 16, title_y, mixColor(bg, fg, 0.6), box_w - 32);

    const now_ms = std.time.milliTimestamp();
    var display: usize = 0;
    while (display < visible) : (display += 1) {
        const i = scroll + display;
        if (i >= total) break;
        const row_top_px = box_top + title_h + row_h * @as(f32, @floatFromInt(display));
        const row_y = @round(window_height - row_top_px - row_h);
        if (i == copilot_picker.selectedIndex()) {
            renderRoundedQuadAlpha(box_x + 8, row_y + 3, box_w - 16, row_h - 6, 5, sel_bg, 0.6);
        }
        const ty = @round(row_y + (row_h - font.g_titlebar_cell_height) / 2);
        if (i == copilot_picker.count()) {
            // Trailing "+ New conversation" action row.
            _ = titlebar.renderTextLimited(i18n.s().copilot_picker_new, box_x + 18, ty, text_color, box_w - 36);
        } else {
            var tbuf: [32]u8 = undefined;
            const rel = copilot_picker.formatRelativeTime(now_ms, copilot_picker.updatedAt(i), &tbuf);
            const rel_w = measureTitlebarText(rel);
            const meta_right = box_x + box_w - 18;
            renderTitlebarText(rel, meta_right - rel_w, ty, meta_color);
            _ = titlebar.renderTextLimited(copilot_picker.titleAt(i), box_x + 18, ty, text_color, (meta_right - rel_w) - (box_x + 18) - 12);
        }
    }
}
```

> If `measureTitlebarText` / `renderTitlebarText` aren't in scope here, use the exact helpers the command-palette history rows use (overlays.zig:1700-1705 calls `measureTitlebarText` + `renderTitlebarText` + `renderTitlebarTextLimited`). Match whatever that block uses.

Wire it into the overlay render path: find where `renderJupyterPicker(...)` is invoked each frame (grep `renderJupyterPicker(` in `AppWindow.zig`/`renderer`), and add a sibling call `overlays.renderCopilotPicker(window_width, window_height);` right after it.

- [ ] **Step 4: Add the input key block (input.zig)**

In `src/input.zig`, add the import near `const jupyter_picker = @import(...)` and insert a key-handling block **before** the `jupyter_picker.isVisible()` block (~line 2749), mirroring its structure. Enter on a conversation row loads it; Enter on the "+ New" row starts a new conversation; Delete removes the selected conversation; Esc closes:

```zig
const copilot_picker = @import("copilot_picker.zig");
```

```zig
if (copilot_picker.isVisible()) {
    switch (ev.key_code) {
        platform_input.key_escape => copilot_picker.hide(),
        platform_input.key_up => copilot_picker.move(-1),
        platform_input.key_down => copilot_picker.move(1),
        platform_input.key_delete => {
            if (!copilot_picker.isNewRowSelected()) {
                AppWindow.deleteCopilotConversationById(copilot_picker.selectedId());
                AppWindow.refreshCopilotPickerRows(); // rebuild from store (may close if empty)
            }
        },
        platform_input.key_enter => {
            if (copilot_picker.isNewRowSelected()) {
                AppWindow.newCopilotConversation();
            } else {
                AppWindow.loadCopilotConversationById(copilot_picker.selectedId());
            }
            copilot_picker.hide();
        },
        else => {},
    }
    AppWindow.g_force_rebuild = true;
    AppWindow.g_cells_valid = false;
    return;
}
```

> `AppWindow.loadCopilotConversationById`, `deleteCopilotConversationById`, `refreshCopilotPickerRows`, and `newCopilotConversation` are added in Task 10. This task can compile-check the render side first; if you implement strictly TDD, do Task 10 before running the full build, or stub these four as `pub fn ...() void {}` here and fill them in Task 10. Prefer doing Task 10 next so no stubs are needed.

- [ ] **Step 5: Run test to verify it passes**

Run: `zig build test-full 2>&1 | tail -20`
Expected: PASS (after Task 10 lands the AppWindow functions; if validating this task alone, the source-embed guards pass once the two symbols exist).

- [ ] **Step 6: Commit**

```bash
git add src/renderer/overlays.zig src/input.zig src/test_main.zig
git commit -m "feat(copilot): render + key-route the copilot conversation picker"
```

---

## Task 10: Load / new / delete / de-dup in AppWindow

**Files:**
- Modify: `src/appwindow/tab.zig` (add `findCopilotTabBySessionId` + `switchToCopilotTabBySessionId`, mirroring `findAiTabBySessionId`/`switchToAiTabBySessionId` at lines 293-307)
- Modify: `src/AppWindow.zig` (add `openCopilotConversationPicker`, `refreshCopilotPickerRows`, `loadCopilotConversationById`, `deleteCopilotConversationById`, `newCopilotConversation`)
- Test: `src/agent_history.zig` already covers `deleteBySessionId`; add a `src/test_main.zig` source-embed guard for the de-dup wiring

- [ ] **Step 1: Write the failing guard**

Add to `src/test_main.zig`:

```zig
test "copilot load de-dups against open tabs" {
    const tab_src = @embedFile("appwindow/tab.zig");
    try std.testing.expect(std.mem.indexOf(u8, tab_src, "pub fn switchToCopilotTabBySessionId(") != null);
    const aw_src = @embedFile("AppWindow.zig");
    // load must consult the open-tab switch before installing a second live copy.
    const load_idx = std.mem.indexOf(u8, aw_src, "pub fn loadCopilotConversationById(") orelse return error.Missing;
    try std.testing.expect(std.mem.indexOf(u8, aw_src[load_idx..], "switchToCopilotTabBySessionId(") != null);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test-full 2>&1 | tail -30`
Expected: FAIL — symbols absent.

- [ ] **Step 3: Add the tab-switch helpers (tab.zig)**

In `src/appwindow/tab.zig`, after `switchToAiTabBySessionId` (line 307), add the Copilot equivalents (a live Copilot conversation lives in a `.terminal` tab's `copilot_session`):

```zig
pub fn findCopilotTabBySessionId(session_id: []const u8) ?usize {
    for (0..g_tab_count) |idx| {
        const t = g_tabs[idx] orelse continue;
        if (t.kind != .terminal) continue;
        const session = t.copilot_session orelse continue;
        if (std.mem.eql(u8, session.sessionId(), session_id)) return idx;
    }
    return null;
}

pub fn switchToCopilotTabBySessionId(session_id: []const u8) bool {
    const idx = findCopilotTabBySessionId(session_id) orelse return false;
    switchTab(idx);
    return true;
}
```

- [ ] **Step 4: Add the AppWindow operations**

In `src/AppWindow.zig`, add (near the other copilot helpers, ~line 4937):

```zig
/// Build the picker rows from the store (copilot records only) and open it.
pub fn openCopilotConversationPicker() void {
    refreshCopilotPickerRows();
    copilot_picker.showFromCurrent(); // see refreshCopilotPickerRows: it already calls show()
}

/// (Re)load picker rows from the store. Called on open and after a delete.
pub fn refreshCopilotPickerRows() void {
    const allocator = g_allocator orelse return;
    g_agent_history_mutex.lock();
    const rows = blk: {
        const store = g_agent_history orelse break :blk &[_]agent_history.Row{};
        break :blk store.buildCopilotRows(allocator) catch &[_]agent_history.Row{};
    };
    g_agent_history_mutex.unlock();
    defer if (rows.len > 0) agent_history.freeRows(allocator, rows);

    var picker_rows: [copilot_picker.MAX_ROWS]copilot_picker.Row = undefined;
    const n = @min(rows.len, copilot_picker.MAX_ROWS);
    for (0..n) |i| picker_rows[i] = .{
        .session_id = rows[i].session_id,
        .title = rows[i].title,
        .updated_at = rows[i].updated_at,
    };
    copilot_picker.show(picker_rows[0..n]);
}

/// Load conversation `session_id` into the active terminal tab's sidebar. If a
/// live copy is already open in some tab, switch to it instead (a second live
/// Session with the same id would corrupt the store).
pub fn loadCopilotConversationById(session_id: []const u8) void {
    if (tab.switchToCopilotTabBySessionId(session_id)) {
        setAiCopilotVisible(true); // ensure the sidebar is shown on that tab
        return;
    }
    const t = tab.activeTab() orelse return;
    if (t.kind != .terminal) return;
    const session = reopenCopilotSessionFromHistorySessionId(session_id) orelse return;
    if (t.copilot_session) |old| old.deinit(); // already saved by its hook
    t.copilot_session = session;
    t.copilot_visible = true;
    setAiCopilotVisible(true);
    postWakeup();
}

pub fn deleteCopilotConversationById(session_id: []const u8) void {
    g_agent_history_mutex.lock();
    defer g_agent_history_mutex.unlock();
    const store = g_agent_history orelse return;
    if (store.deleteBySessionId(session_id)) markAgentHistoryDirtyLocked();
}

/// Start a fresh, empty Copilot conversation on the active terminal tab.
pub fn newCopilotConversation() void {
    const t = tab.activeTab() orelse return;
    if (t.kind != .terminal) return;
    if (t.copilot_session) |old| {
        old.deinit(); // already persisted by its hook if non-empty
        t.copilot_session = null;
    }
    _ = ensureActiveCopilotSession();
    t.copilot_visible = true;
    setAiCopilotVisible(true);
    postWakeup();
}
```

Add the import at the top of `AppWindow.zig` near the other module imports:

```zig
const copilot_picker = @import("copilot_picker.zig");
```

> Notes:
> - `setAiCopilotVisible(true)` / `aiCopilotVisible()` — use the existing copilot-visibility setter. Grep `aiCopilotVisible` to find the matching setter (the toggle is `toggleAiCopilot`). If only a toggle exists, add a `setAiCopilotVisible(visible: bool)` that sets the same flag the toggle flips.
> - `postWakeup()` — the event-driven UI refresh (background/main-thread state changed). It's the established way to force a redraw from a non-render path; grep `postWakeup(` for the exact name in your tree.
> - Drop the `showFromCurrent()` line in `openCopilotConversationPicker` — `refreshCopilotPickerRows()` already calls `copilot_picker.show(...)`. Final body is just `refreshCopilotPickerRows();`.

- [ ] **Step 5: Run test to verify it passes**

Run: `zig build test-full 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/appwindow/tab.zig src/AppWindow.zig src/test_main.zig
git commit -m "feat(copilot): load/new/delete copilot conversations with de-dup"
```

---

## Task 11: `/resume` context-aware in the sidebar

**Files:**
- Modify: `src/ai_chat.zig` (add `DeferredAction.copilot_conversation_picker` ~line 335; `g_copilot_picker_trigger` + setter ~line 371/417; handle it in `fireDeferredAction` ~line 353; branch `.resume_session` in `runBuiltinCommandLocked` ~line 2591)
- Modify: `src/ai_chat_composer.zig` (context-aware `/resume` description via a builder)
- Modify: `src/AppWindow.zig` (register the trigger near line 144)
- Test: `src/ai_chat.zig` (pure branch test) + `src/ai_chat_composer.zig` (description test); `zig build test-full` + `zig build test`

- [ ] **Step 1: Write the failing tests**

Add to `src/ai_chat.zig`:

```zig
test "/resume defers to copilot picker for copilot sessions, external resume otherwise" {
    const allocator = std.testing.allocator;
    const copilot = try Session.init(allocator, "Copilot", "https://x", "k", "m", "s", "disabled", "low", "true", "true");
    defer copilot.deinit();
    copilot.copilot = true;
    {
        copilot.mutex.lock();
        defer copilot.mutex.unlock();
        const r = copilot.runBuiltinCommandLocked(.resume_session, "");
        try std.testing.expectEqual(DeferredAction.copilot_conversation_picker, r.deferred);
    }

    const tabchat = try Session.init(allocator, "Chat", "https://x", "k", "m", "s", "disabled", "low", "true", "true");
    defer tabchat.deinit();
    {
        tabchat.mutex.lock();
        defer tabchat.mutex.unlock();
        const r = tabchat.runBuiltinCommandLocked(.resume_session, "");
        try std.testing.expectEqual(DeferredAction.resume_picker, r.deferred);
    }
}
```

Add to `src/ai_chat_composer.zig`:

```zig
test "resume description is context-aware" {
    try std.testing.expectEqualStrings(
        "load a past Copilot conversation",
        resumeDescription(true),
    );
    try std.testing.expectEqualStrings(
        "resume an external CLI session in a terminal",
        resumeDescription(false),
    );
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test-full 2>&1 | tail -30` then `zig build test 2>&1 | tail -30`
Expected: FAIL — `copilot_conversation_picker` not in `DeferredAction`; `resumeDescription` undefined.

- [ ] **Step 3: Extend `DeferredAction`, trigger, and dispatch (ai_chat.zig)**

Add the variant (line 335-340):

```zig
const DeferredAction = union(enum) {
    none,
    resume_picker,
    copilot_conversation_picker,
    model_switch_picker,
    export_markdown: MarkdownExportMode,
};
```

Add the trigger global + setter (near line 371 / 417):

```zig
var g_copilot_picker_trigger: ?*const fn () void = null;

pub fn setCopilotPickerTrigger(cb: ?*const fn () void) void {
    g_copilot_picker_trigger = cb;
}
```

Handle it in `fireDeferredAction` (line 353-362):

```zig
fn fireDeferredAction(session: *Session, action: DeferredAction) void {
    switch (action) {
        .none => {},
        .resume_picker => if (g_session_resume_trigger) |t| t(),
        .copilot_conversation_picker => if (g_copilot_picker_trigger) |t| t(),
        .model_switch_picker => if (g_model_switch_trigger) |t| t(session),
        .export_markdown => |mode| if (g_markdown_export_trigger) |t| t(mode),
    }
}
```

Branch `.resume_session` in `runBuiltinCommandLocked` (line 2591) — `self` is in scope:

```zig
        .resume_session => result.deferred = if (self.copilot)
            .copilot_conversation_picker
        else
            .resume_picker,
```

(Optionally update the `.resume_session` arm of `slashCommandOutput` at line 699 to a neutral message like `"Opening saved conversations..."` so it reads correctly in both contexts.)

- [ ] **Step 4: Context-aware description (ai_chat_composer.zig)**

In `src/ai_chat_composer.zig`, add a helper and use it where suggestions are built. Keep the static `slash_command_entries` array (its `/resume` description becomes the default/fallback) and override at the point suggestions are rendered:

```zig
pub fn resumeDescription(copilot: bool) []const u8 {
    return if (copilot)
        "load a past Copilot conversation"
    else
        "resume an external CLI session in a terminal";
}
```

Then, wherever the suggestion list is built for display (grep `slash_command_entries` consumers in this file / `ai_chat.zig`), when emitting the `/resume` entry, substitute `resumeDescription(session.copilot)` for `entry.suggestion.description`. If the suggestion builder doesn't currently receive the session/copilot flag, thread a `copilot: bool` parameter into that one builder function (the spec's intended approach). If threading proves invasive, the fallback is to set the static description to a single clarified combined string — but prefer the threaded version.

- [ ] **Step 5: Register the trigger (AppWindow.zig)**

Near the existing `ai_chat.setSessionResumeTrigger(...)` registration (line 144):

```zig
ai_chat.setCopilotPickerTrigger(struct {
    fn cb() void {
        openCopilotConversationPicker();
    }
}.cb);
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `zig build test-full 2>&1 | tail -20` then `zig build test 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add src/ai_chat.zig src/ai_chat_composer.zig src/AppWindow.zig
git commit -m "feat(copilot): make /resume open the copilot picker in the sidebar"
```

---

## Task 12: Command-center command

**Files:**
- Modify: `src/command_center_state.zig` (add `CommandAction.load_copilot_conversation` ~line 47; catalog entry ~line 64)
- Modify: `src/i18n.zig` (title switch ~line 738; detail switch ~line 790; both `commandTitle` and `commandDetail`)
- Modify: `src/renderer/overlays.zig` (`executeCommand` arm ~line 555)
- Test: `src/command_center_state.zig` (`findCommandAction` test exists at line 302; add one); `zig build test`

- [ ] **Step 1: Write the failing test**

Add to `src/command_center_state.zig` (next to the existing `findCommandAction` test ~line 302):

```zig
test "command catalog includes Load Copilot Conversation" {
    try std.testing.expectEqual(
        CommandAction.load_copilot_conversation,
        findCommandAction("Load Copilot Conversation"),
    );
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | tail -30`
Expected: FAIL — `no field named 'load_copilot_conversation'` in `CommandAction`.

- [ ] **Step 3: Add the action + catalog entry (command_center_state.zig)**

Add the variant to the `CommandAction` enum (e.g. right after `select_agent_history` at line 11):

```zig
    select_agent_history,
    load_copilot_conversation,
```

Add a `command_entries` row (after the `Select Copilot History` entry at line 64):

```zig
    .{ .title = "Load Copilot Conversation", .detail = "Reopen a saved Copilot sidebar conversation", .shortcut = "", .action = .load_copilot_conversation },
```

- [ ] **Step 4: Add i18n translations (i18n.zig)**

In `commandTitle`'s `switch` (after `.select_agent_history => "选择副驾历史",` ~line 742):

```zig
        .load_copilot_conversation => "载入副驾对话",
```

In `commandDetail`'s `switch` (after `.select_agent_history => "打开命令中心的副驾历史选择器",` ~line 794):

```zig
        .load_copilot_conversation => "重新打开已保存的副驾侧栏对话",
```

> Both switches are exhaustive (no `else`), so the new enum variant forces an arm in each — the compiler will tell you if either is missing.

- [ ] **Step 5: Dispatch the command (overlays.zig)**

In `executeCommand` (line 548), add an arm (after `.select_agent_history => commandPaletteOpenAgentHistory(),`):

```zig
        .load_copilot_conversation => AppWindow.openCopilotConversationPicker(),
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `zig build test 2>&1 | tail -20` then `zig build test-full 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add src/command_center_state.zig src/i18n.zig src/renderer/overlays.zig
git commit -m "feat(copilot): add command-center 'Load Copilot Conversation' command"
```

---

## Task 13: Dedicated keyboard shortcut

**Files:**
- Modify: `src/keybind.zig` (add `Action.copilot_conversation_picker` ~line 67; default binding ~line 418)
- Modify: `src/input.zig` (dispatch arm ~line 2617)
- Modify: `src/input/command_dispatch.zig` (if the action must be mapped there too — mirror `.toggle_ai_copilot` at line 57)
- Test: `src/keybind.zig` inline test or a `src/test_main.zig` source-embed guard

- [ ] **Step 1: Write the failing guard**

Add to `src/test_main.zig`:

```zig
test "copilot conversation picker has a keybind action and dispatch" {
    const kb_src = @embedFile("keybind.zig");
    try std.testing.expect(std.mem.indexOf(u8, kb_src, "copilot_conversation_picker") != null);
    const input_src = @embedFile("input.zig");
    try std.testing.expect(std.mem.indexOf(u8, input_src, ".copilot_conversation_picker =>") != null);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test-full 2>&1 | tail -30`
Expected: FAIL — action/dispatch absent.

- [ ] **Step 3: Add the action + default binding (keybind.zig)**

Add to the `Action` enum (after `toggle_ai_copilot` at line 67):

```zig
    copilot_conversation_picker,
```

Add a default binding to the bindings table (near line 418). Pick a free chord — `Ctrl+Shift+R` (R for "resume"); verify it isn't already taken in the table, and adjust if so:

```zig
    .{ .trigger = .{ .mods = .{ .ctrl = true, .shift = true }, .key_code = 'R' }, .action = .copilot_conversation_picker },
```

> If `Ctrl+Shift+R` collides, choose another unused chord and note it. On macOS the bindings layer maps Ctrl→Cmd per existing convention — follow whatever `toggle_ai_copilot`'s entry does.

- [ ] **Step 4: Dispatch the action (input.zig + command_dispatch.zig)**

In `src/input.zig`, in the keybind-action `switch` (after `.toggle_ai_copilot => AppWindow.toggleAiCopilot(),` at line 2617):

```zig
        .copilot_conversation_picker => AppWindow.openCopilotConversationPicker(),
```

If `src/input/command_dispatch.zig` has a parallel mapping (line 57 maps `.toggle_ai_copilot => .toggle_ai_copilot`), add the analogous arm there so the action survives that layer:

```zig
            .copilot_conversation_picker => .copilot_conversation_picker,
```

(Only if that file's enum is the same `keybind.Action` surface; if it's a separate command enum, add the matching variant and dispatch.)

- [ ] **Step 5: Run tests to verify they pass**

Run: `zig build test-full 2>&1 | tail -20` then `zig build test 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/keybind.zig src/input.zig src/input/command_dispatch.zig
git commit -m "feat(copilot): add keyboard shortcut to open the copilot picker"
```

---

## Task 14: i18n strings for the picker overlay

**Files:**
- Modify: `src/i18n.zig` (`Strings` struct + both `en` and `zh_CN` literals)
- Test: `src/i18n.zig` compiles only if every language fills every field (comptime); no extra test needed beyond the build.

> This task is a dependency of Task 9 (the render references `i18n.s().copilot_picker_title` / `.copilot_picker_new`). Do it **before or together with** Task 9. It is listed last only to keep the i18n edits in one place; if executing in order, hoist this to run right before Task 9.

- [ ] **Step 1: Add struct fields**

In `src/i18n.zig`, add to the `Strings` struct (near the `cmd_palette_*` group ~line 191):

```zig
    copilot_picker_title: []const u8,
    copilot_picker_new: []const u8,
    copilot_picker_empty: []const u8,
```

- [ ] **Step 2: Fill the `en` literal**

In the `const en = Strings{ ... }` block (~line 397):

```zig
    .copilot_picker_title = "Copilot conversations (Up/Down, Enter, Delete, Esc)",
    .copilot_picker_new = "+ New conversation",
    .copilot_picker_empty = "No saved Copilot conversations",
```

- [ ] **Step 3: Fill the `zh_CN` literal**

In the `const zh_CN = Strings{ ... }` block (~line 601):

```zig
    .copilot_picker_title = "副驾对话（上下选择，回车打开，Delete 删除，Esc 关闭）",
    .copilot_picker_new = "+ 新建对话",
    .copilot_picker_empty = "没有已保存的副驾对话",
```

- [ ] **Step 4: Verify it compiles**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS (a missing field in either language is a comptime error).

- [ ] **Step 5: Commit**

```bash
git add src/i18n.zig
git commit -m "feat(copilot): add i18n strings for the copilot picker"
```

---

## Final verification

- [ ] **Run the fast suite:** `zig build test 2>&1 | tail -20` → all green.
- [ ] **Run the full suite:** `zig build test-full 2>&1 | tail -30` → all green.
- [ ] **Manual smoke (macOS):** `zig build macos-app -Dtarget=aarch64-macos`, launch, then:
  1. Open a terminal tab, `Ctrl/Cmd+Shift+A` to show Copilot, chat one turn.
  2. Quit and relaunch (with restore-tabs enabled) → the conversation reloads in place; sidebar open state matches.
  3. Close the terminal tab, then `Ctrl/Cmd+Shift+R` (or `/resume` in a sidebar, or command center → "Load Copilot Conversation") → the conversation is in the picker; Enter reloads it.
  4. In the picker, Delete removes a conversation; "+ New conversation" starts a fresh one.
  5. Open the same conversation while it's already live in another tab → it switches to that tab (no duplicate).
  6. A never-chatted sidebar does not appear in the picker and is not restored.

---

## Self-Review

**Spec coverage** (each spec section → task):
- Store record marker (`copilot: bool`) → Task 1 (struct + clone) + Task 2 (write/read in ai_chat).
- Tab snapshot fields (`copilot_session_id`, `copilot_visible`) → Task 4.
- Write path 1 (incremental hook in `activeCopilotSession`) → Task 5.
- Write path 2 (quit snapshot over `.terminal` tabs) → Task 6.
- Write path 3 (snapshot id in `snapshotTab`) → Task 5.
- Restore in place → Task 7.
- Picker (rows = copilot==true, title+time, newest-first; load/new/delete; de-dup) → Task 8 (state + `buildCopilotRows`) + Task 9 (render+input) + Task 10 (load/new/delete/de-dup).
- Entry points: command center → Task 12; `/resume` → Task 11; dedicated shortcut → Task 13. (On-screen sidebar button: deferred, see Scope notes.)
- `/resume` context-aware (branch on `Session.copilot`; context-aware description) → Task 11.
- Edge cases: empty conversation (`shouldPersistCopilot`) → Task 3, applied in Tasks 5/6; closed terminal tab retained → inherent (store keyed by id, not freed on tab close); missing id on restore → Task 7 silent fallback; same id live twice → Task 10 de-dup; record accumulation/manual delete → Task 10.
- Testing section → covered by the per-task tests (round-trips, predicate, picker row building, `/resume` branch).

**Type consistency check:** `copilot` (bool) is named identically across `SessionRecord`, `Session`, `cloneRecord`, `toHistoryRecordLocked`, `initFromHistoryRecord`. `copilot_session_id` / `copilot_visible` match between `TabSnap`, `snapshotTab`, and `restoreTab`. The restore hook signature `?*const fn ([]const u8) ?*ai_chat.Session` is declared once in `tab.zig` (`g_copilot_restore_hook`) and implemented once in `AppWindow.zig` (`reopenCopilotSessionFromHistorySessionId`). Picker accessors (`isVisible`, `show`, `move`, `selectedId`, `rowCount`, `isNewRowSelected`, `formatRelativeTime`) are referenced consistently by `renderCopilotPicker` and the input block. AppWindow surface (`openCopilotConversationPicker`, `refreshCopilotPickerRows`, `loadCopilotConversationById`, `deleteCopilotConversationById`, `newCopilotConversation`) is referenced consistently by input.zig, overlays.zig `executeCommand`, and the keybind/trigger registration.

**Known unknowns to confirm against the live tree while implementing** (flagged inline in the tasks, not placeholders):
- Exact arity of `Session.init(...)` in test helpers — mirror an existing in-file call.
- Exact `Message{...}` minimal literal — mirror `initFromHistoryRecord`.
- The setter for copilot sidebar visibility (`setAiCopilotVisible` vs only a toggle) and `postWakeup` name — grep and match.
- The per-frame call site of `renderJupyterPicker` to add the `renderCopilotPicker` sibling.
- Whether `command_dispatch.zig` needs a parallel keybind arm.
