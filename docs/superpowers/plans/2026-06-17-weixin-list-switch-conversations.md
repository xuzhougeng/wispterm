# WeChat /list + /switch conversation switching — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a WeChat-direct user list every open AI conversation (dedicated AI-chat tabs **and** terminal-tab Copilot sidebars) and pin WeChat to any one of them via `/list` and `/switch <n>`, with a lightweight digest pushed on switch.

**Architecture:** Three layers mirror the existing bridge. (1) Pure routing/formatting in `weixin/agent.zig` + a new pure `weixin/session_list.zig`. (2) A `Control` vtable extended with conversation enumeration + pinning, using **fixed-size inline buffers** (`Conversation`/`ConversationList`) so marshaling needs no allocator. (3) `AppWindow.zig` owns a UI-thread `g_weixin_pinned_session` pointer; the single resolver `weixinActiveAiTabIndex()` becomes pin-aware and every consumer falls through `ai_chat_session orelse copilot_session`.

**Tech Stack:** Zig 0.15.2. Tests via `zig build test` (fast native), `zig build test-full` (full suite), `zig build -Dtarget=x86_64-windows-gnu` (Windows cross-compile — the bridge is Windows-only at runtime).

**Spec:** `docs/superpowers/specs/2026-06-17-weixin-list-switch-conversations-design.md`

> **Note vs. spec:** the spec sketched the vtable as `list_ai_conversations(ctx, allocator) -> ![]Conversation`. This plan refines that to allocation-free fixed-buffer out-params (`*ConversationList` / `*Conversation`), which is simpler, matches the codebase's inline-buffer idiom (e.g. `Session.title_buf`), and removes cross-thread allocator juggling. Same external behavior.

## File structure

- **`src/weixin/control.zig`** (modify) — owns the seam types. Add `Conversation`, `ConversationList`, `copyClamp`, two vtable entries + `Control` wrapper methods. Update its in-file test `Fake`.
- **`src/weixin/session_list.zig`** (create) — pure formatters: `tailLines`, `writeList`, `writeDigest`, `appendFmt`. Fully unit-tested. Imports `control.zig` only for the `Conversation` type.
- **`src/weixin/agent.zig`** (modify) — route `/list`/`/sessions`/`/ls` and `/switch`/`/use`; update `/help`, `/status`, the known-command whitelist, the no-arg gate, `usageText`. Extend `FakeControl` with a conversation fixture. New route tests.
- **`src/weixin/controller.zig`** (modify) — add the two new methods to its `NoopControl` test fake (compile-only).
- **`src/AppWindow.zig`** (modify) — `g_weixin_pinned_session`, `tabConversationSession`, pin-aware `weixinActiveAiTabIndex`, copilot fallthrough in all five consumers, two new `WeixinRequest` ops + handlers, two real vtable wrappers.

## Task ordering rationale

Adding a vtable method is a breaking change for **every** implementor (the in-file `Fake` in control.zig, `NoopControl` in controller.zig, `FakeControl` in agent.zig, and the real `weixin_vtable` in AppWindow.zig). To keep every commit green:

1. **Task 1** adds only the *types* to control.zig (purely additive).
2. **Task 2** builds the pure formatters on those types.
3. **Task 3** adds the *vtable methods* and updates **all** implementors at once (real fixture in `FakeControl`, real impl in AppWindow is deferred to Task 5 via a trivial stub).
4. **Task 4** wires the commands + tests (uses Tasks 2 & 3).
5. **Task 5** replaces the AppWindow stubs with the real pin/resolver/handlers.

---

## Task 1: Conversation seam types

**Files:**
- Modify: `src/weixin/control.zig` (add types near `Surface` at line 6; add a test at end)

- [ ] **Step 1: Write the failing test**

Add at the end of `src/weixin/control.zig` (before the final closing of the test block region, after the existing `inboundFileDir` test):

```zig
test "Conversation setters clamp on UTF-8 boundaries" {
    var c: Conversation = .{};
    try t.expectEqualStrings("", c.title());

    c.setTitle("Claude");
    try t.expectEqualStrings("Claude", c.title());

    c.setModel("glm-5.2");
    try t.expectEqualStrings("glm-5.2", c.model());

    // A 3-byte CJK char must never be split when it overflows the buffer.
    var big: [400]u8 = undefined;
    var i: usize = 0;
    while (i + 3 <= big.len) : (i += 3) {
        big[i] = 0xE4;
        big[i + 1] = 0xBD;
        big[i + 2] = 0xA0; // "你"
    }
    c.setTitle(big[0..i]);
    try t.expect(c.title().len <= 128);
    try t.expect(std.unicode.utf8ValidateSlice(c.title()));
}

test "ConversationList slice reflects count" {
    var list: ConversationList = .{};
    try t.expectEqual(@as(usize, 0), list.slice().len);
    list.items[0].setTitle("A");
    list.items[1].setTitle("B");
    list.count = 2;
    try t.expectEqual(@as(usize, 2), list.slice().len);
    try t.expectEqualStrings("B", list.slice()[1].title());
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `zig build test 2>&1 | head -30`
Expected: FAIL — `Conversation`/`ConversationList` are undefined.

- [ ] **Step 3: Add the types**

In `src/weixin/control.zig`, immediately after the `Surface` definition (line 6 `pub const Surface = struct { id: [16]u8, title: []const u8 };`), insert:

```zig
/// A single AI conversation as seen by the WeChat bridge: a dedicated AI-chat
/// tab or a terminal tab's Copilot sidebar. Uses fixed inline buffers so the
/// whole struct is a POD value that marshals across the UI-thread boundary with
/// no allocation (mirrors ai_chat.Session's title_buf style).
pub const Conversation = struct {
    title_buf: [128]u8 = undefined,
    title_len: usize = 0,
    model_buf: [64]u8 = undefined,
    model_len: usize = 0,
    cwd_buf: [256]u8 = undefined,
    cwd_len: usize = 0,
    busy: bool = false,
    is_copilot: bool = false,
    is_current: bool = false,

    pub fn title(self: *const Conversation) []const u8 {
        return self.title_buf[0..self.title_len];
    }
    pub fn model(self: *const Conversation) []const u8 {
        return self.model_buf[0..self.model_len];
    }
    pub fn cwd(self: *const Conversation) []const u8 {
        return self.cwd_buf[0..self.cwd_len];
    }
    pub fn setTitle(self: *Conversation, s: []const u8) void {
        self.title_len = copyClamp(&self.title_buf, s);
    }
    pub fn setModel(self: *Conversation, s: []const u8) void {
        self.model_len = copyClamp(&self.model_buf, s);
    }
    pub fn setCwd(self: *Conversation, s: []const u8) void {
        self.cwd_len = copyClamp(&self.cwd_buf, s);
    }
};

/// A bounded list of conversations (one per tab; tabs are capped at 32).
pub const ConversationList = struct {
    items: [32]Conversation = undefined,
    count: usize = 0,

    pub fn slice(self: *const ConversationList) []const Conversation {
        return self.items[0..self.count];
    }
};

/// Copy `s` into `buf`, clamped to fit and never splitting a UTF-8 sequence.
/// Returns the number of bytes written.
fn copyClamp(buf: []u8, s: []const u8) usize {
    var n = @min(buf.len, s.len);
    while (n > 0 and n < s.len and (s[n] & 0xC0) == 0x80) : (n -= 1) {}
    @memcpy(buf[0..n], s[0..n]);
    return n;
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS (all tests, including the two new ones).

- [ ] **Step 5: Commit**

```bash
git add src/weixin/control.zig
git commit -m "feat(weixin): add Conversation/ConversationList seam types"
```

---

## Task 2: Pure list & digest formatters

**Files:**
- Create: `src/weixin/session_list.zig`
- Modify: `build.zig` is NOT needed — Zig test discovery for the weixin suite imports modules transitively; this module is reached via `agent.zig` (Task 4). To get its tests run *now*, temporarily reference it. See Step 2 note.

- [ ] **Step 1: Write the failing tests (and the module skeleton)**

Create `src/weixin/session_list.zig`:

```zig
//! Pure formatters for the WeChat /list and /switch replies. No IO, no GUI —
//! unit-tested directly. Operates on control.Conversation values produced by
//! the Control vtable.
const std = @import("std");
const control = @import("control.zig");
const Conversation = control.Conversation;

/// Append a formatted segment to an unmanaged byte list.
fn appendFmt(
    buf: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    const s = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(s);
    try buf.appendSlice(allocator, s);
}

/// Return the last `max_lines` lines of `s`, further clipped to at most
/// `max_bytes` bytes kept from the end (never splitting a UTF-8 sequence).
/// Trailing blank lines are trimmed first. The result borrows from `s`.
pub fn tailLines(s: []const u8, max_lines: usize, max_bytes: usize) []const u8 {
    const trimmed = std.mem.trimRight(u8, s, " \t\r\n");
    if (trimmed.len == 0) return trimmed;
    var start: usize = trimmed.len;
    var seen: usize = 0;
    var i: usize = trimmed.len;
    while (i > 0) : (i -= 1) {
        if (trimmed[i - 1] == '\n') {
            seen += 1;
            if (seen == max_lines) break;
        }
        start = i - 1;
    }
    var tail = trimmed[start..];
    if (tail.len > max_bytes) {
        var b = tail.len - max_bytes;
        while (b < tail.len and (tail[b] & 0xC0) == 0x80) : (b += 1) {}
        tail = tail[b..];
    }
    return tail;
}

/// Render the /list reply into `buf`.
pub fn writeList(
    buf: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    convs: []const Conversation,
) !void {
    if (convs.len == 0) {
        try buf.appendSlice(allocator, "当前没有副驾会话，发送任意消息可自动打开。");
        return;
    }
    try appendFmt(buf, allocator, "副驾会话（共 {d} 个）：\n", .{convs.len});
    var any_current = false;
    for (convs, 0..) |c, idx| {
        if (c.is_current) any_current = true;
        const marker: []const u8 = if (c.is_current) "➤ " else "  ";
        const tag: []const u8 = if (c.is_copilot) " · 副驾" else "";
        const state: []const u8 = if (c.busy) "忙" else "闲";
        try appendFmt(buf, allocator, "{d}. {s}{s}{s}  [{s}]  {s}\n", .{
            idx + 1, marker, c.title(), tag, c.model(), state,
        });
    }
    if (!any_current) {
        try buf.appendSlice(allocator, "（当前默认：发送消息将新建副驾会话）\n");
    }
    try buf.appendSlice(allocator, "发送 /switch <编号> 切换；微信将固定到所选会话。");
}

/// Render the post-switch digest into `buf`. `idx1` is the 1-based number the
/// user selected; `tail` is a short transcript excerpt (may be empty).
pub fn writeDigest(
    buf: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    idx1: usize,
    c: Conversation,
    tail: []const u8,
) !void {
    const tag: []const u8 = if (c.is_copilot) " · 副驾" else "";
    const state: []const u8 = if (c.busy) "忙" else "闲";
    try appendFmt(buf, allocator, "已切换到会话 {d}：{s}{s}\n模型：{s}\n", .{
        idx1, c.title(), tag, c.model(),
    });
    if (c.cwd().len != 0) try appendFmt(buf, allocator, "目录：{s}\n", .{c.cwd()});
    try appendFmt(buf, allocator, "状态：{s}\n", .{state});
    if (tail.len != 0) try appendFmt(buf, allocator, "最近：\n{s}\n", .{tail});
    try buf.appendSlice(allocator, "（已固定，后续消息将发送到此会话。本摘要仅供参考，未作为对话上下文。）");
}

const t = std.testing;

test "tailLines keeps the last N lines" {
    try t.expectEqualStrings("c\nd", tailLines("a\nb\nc\nd", 2, 100));
    try t.expectEqualStrings("hello", tailLines("hello", 5, 100));
    try t.expectEqualStrings("x", tailLines("x\n\n\n", 3, 100));
}

test "tailLines clips bytes on a UTF-8 boundary" {
    // 4 CJK chars (3 bytes each = 12 bytes); a 7-byte budget must back off to
    // the last 2 whole chars (6 bytes), never a partial char.
    const out = tailLines("你好世界", 5, 7);
    try t.expect(out.len <= 7);
    try t.expect(std.unicode.utf8ValidateSlice(out));
    try t.expectEqualStrings("世界", out);
}

test "writeList renders count, current marker, copilot tag, busy state" {
    var c0: Conversation = .{};
    c0.setTitle("Claude");
    c0.setModel("glm-5.2");
    c0.is_current = true;
    var c1: Conversation = .{};
    c1.setTitle("zsh ~/p");
    c1.setModel("opus");
    c1.is_copilot = true;
    c1.busy = true;
    const convs = [_]Conversation{ c0, c1 };

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(t.allocator);
    try writeList(&buf, t.allocator, &convs);
    const s = buf.items;
    try t.expect(std.mem.indexOf(u8, s, "共 2 个") != null);
    try t.expect(std.mem.indexOf(u8, s, "➤") != null);
    try t.expect(std.mem.indexOf(u8, s, "· 副驾") != null);
    try t.expect(std.mem.indexOf(u8, s, "忙") != null);
    try t.expect(std.mem.indexOf(u8, s, "闲") != null);
}

test "writeList empty" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(t.allocator);
    try writeList(&buf, t.allocator, &.{});
    try t.expect(std.mem.indexOf(u8, buf.items, "没有副驾会话") != null);
}

test "writeList notes default when nothing is current" {
    var c0: Conversation = .{};
    c0.setTitle("only-copilot");
    c0.is_copilot = true;
    const convs = [_]Conversation{c0};
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(t.allocator);
    try writeList(&buf, t.allocator, &convs);
    try t.expect(std.mem.indexOf(u8, buf.items, "将新建副驾会话") != null);
}

test "writeDigest includes title, model, footer; cwd/tail optional" {
    var c: Conversation = .{};
    c.setTitle("B");
    c.setModel("m2");
    c.setCwd("/home/x/p");
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(t.allocator);
    try writeDigest(&buf, t.allocator, 2, c, "last line");
    const s = buf.items;
    try t.expect(std.mem.indexOf(u8, s, "已切换到会话 2：B") != null);
    try t.expect(std.mem.indexOf(u8, s, "模型：m2") != null);
    try t.expect(std.mem.indexOf(u8, s, "目录：/home/x/p") != null);
    try t.expect(std.mem.indexOf(u8, s, "最近：\nlast line") != null);
    try t.expect(std.mem.indexOf(u8, s, "未作为对话上下文") != null);
}
```

- [ ] **Step 2: Run the tests to verify they fail, then pass**

Note: the fast `test` step runs `src/test_main.zig`'s referenced modules. To ensure `session_list.zig`'s tests execute, confirm it is reached. Run the dedicated file test directly first:

Run: `zig test src/weixin/session_list.zig 2>&1 | tail -20`
Expected: PASS (this compiles the file with its imports and runs its tests in isolation).

(If `zig test` reports an import path issue for `control.zig`, run from the repo root so the relative import resolves; the file lives beside `control.zig`.)

- [ ] **Step 3: (no separate implementation step — module written in Step 1)**

The implementation and tests were written together in Step 1 because the formatters are small and cohesive.

- [ ] **Step 4: Run the full fast suite**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS. (The module is not yet imported by the app graph; that happens in Task 4. The isolated `zig test` in Step 2 is the gate for this task.)

- [ ] **Step 5: Commit**

```bash
git add src/weixin/session_list.zig
git commit -m "feat(weixin): pure /list + /switch reply formatters"
```

---

## Task 3: Extend the Control vtable (all implementors)

**Files:**
- Modify: `src/weixin/control.zig:18-30` (VTable), add wrapper methods after line 58; update the in-file `Fake` (lines ~64-107).
- Modify: `src/weixin/controller.zig` — `NoopControl` (lines ~490-531).
- Modify: `src/weixin/agent.zig` — `FakeControl` (lines ~179-258) with a real fixture.
- Modify: `src/AppWindow.zig` — add stub wrappers + vtable entries (real impl in Task 5).

- [ ] **Step 1: Add the vtable entries + Control wrappers**

In `src/weixin/control.zig`, inside `pub const VTable = struct { ... }` (after the `inbound_file_dir` field at line 29), add:

```zig
        /// Fill `out` with every open AI conversation (dedicated AI-chat tabs and
        /// terminal-tab Copilot sidebars), in tab order. UI-thread backed.
        list_ai_conversations: *const fn (ctx: *anyopaque, out: *ConversationList) void,
        /// Pin the Nth conversation (0-based, same order as list_ai_conversations).
        /// On success fills `out` and returns true; false if out of range.
        pin_ai_conversation_by_index: *const fn (ctx: *anyopaque, idx0: usize, out: *Conversation) bool,
```

Then, after the `inboundFileDir` wrapper (line 56-58), add:

```zig
    pub fn listAiConversations(self: Control, out: *ConversationList) void {
        self.vtable.list_ai_conversations(self.ctx, out);
    }
    pub fn pinAiConversationByIndex(self: Control, idx0: usize, out: *Conversation) bool {
        return self.vtable.pin_ai_conversation_by_index(self.ctx, idx0, out);
    }
```

- [ ] **Step 2: Update the control.zig in-file `Fake`**

In the `inboundFileDir forwards...` test's `Fake` struct (around line 89), add two methods before `var dummy`:

```zig
        fn list_ai_conversations(_: *anyopaque, out: *ConversationList) void {
            out.count = 0;
        }
        fn pin_ai_conversation_by_index(_: *anyopaque, _: usize, _: *Conversation) bool {
            return false;
        }
```

And add them to the vtable literal inside `iface()` (after `.inbound_file_dir = inbound_file_dir,`):

```zig
                .list_ai_conversations = list_ai_conversations,
                .pin_ai_conversation_by_index = pin_ai_conversation_by_index,
```

- [ ] **Step 3: Update controller.zig `NoopControl`**

In `src/weixin/controller.zig`, in `NoopControl` (after `inbound_file_dir` at ~line 515), add:

```zig
    fn list_ai_conversations(_: *anyopaque, out: *control_mod.ConversationList) void {
        out.count = 0;
    }
    fn pin_ai_conversation_by_index(_: *anyopaque, _: usize, _: *control_mod.Conversation) bool {
        return false;
    }
```

And in its `iface()` vtable literal (after `.inbound_file_dir = inbound_file_dir,`):

```zig
            .list_ai_conversations = list_ai_conversations,
            .pin_ai_conversation_by_index = pin_ai_conversation_by_index,
```

- [ ] **Step 4: Update agent.zig `FakeControl` with a real fixture**

In `src/weixin/agent.zig`, add fixture fields to `FakeControl` (after `last_resolve_approve: bool = false,` ~line 189):

```zig
    // Conversation fixture for /list and /switch tests.
    conv_titles: []const []const u8 = &.{},
    conv_models: []const []const u8 = &.{},
    conv_busy: []const bool = &.{},
    conv_copilot: []const bool = &.{},
    conv_current: ?usize = null,
    pin_called_index: ?usize = null,
```

Add the two methods (before `fn cast` ~line 237):

```zig
    fn list_ai_conversations(ctx: *anyopaque, out: *control.ConversationList) void {
        const self = cast(ctx);
        var n: usize = 0;
        for (self.conv_titles, 0..) |title_v, i| {
            if (n >= out.items.len) break;
            var c = &out.items[n];
            c.* = .{};
            c.setTitle(title_v);
            if (i < self.conv_models.len) c.setModel(self.conv_models[i]);
            if (i < self.conv_busy.len) c.busy = self.conv_busy[i];
            if (i < self.conv_copilot.len) c.is_copilot = self.conv_copilot[i];
            c.is_current = (self.conv_current != null and self.conv_current.? == i);
            n += 1;
        }
        out.count = n;
    }
    fn pin_ai_conversation_by_index(ctx: *anyopaque, idx0: usize, out: *control.Conversation) bool {
        const self = cast(ctx);
        if (idx0 >= self.conv_titles.len) return false;
        self.pin_called_index = idx0;
        out.* = .{};
        out.setTitle(self.conv_titles[idx0]);
        if (idx0 < self.conv_models.len) out.setModel(self.conv_models[idx0]);
        if (idx0 < self.conv_copilot.len) out.is_copilot = self.conv_copilot[idx0];
        out.is_current = true;
        return true;
    }
```

And in `control_iface()`'s vtable literal (after `.inbound_file_dir = inbound_file_dir,`):

```zig
            .list_ai_conversations = list_ai_conversations,
            .pin_ai_conversation_by_index = pin_ai_conversation_by_index,
```

- [ ] **Step 5: Add stub wrappers + vtable entries in AppWindow.zig**

In `src/AppWindow.zig`, after `wxInboundFileDir` (ends ~line 5903), add:

```zig
fn wxListAiConversations(_: *anyopaque, out: *weixin_control.ConversationList) void {
    // Real UI-thread enumeration is added in the pin/resolver task.
    out.count = 0;
}

fn wxPinAiConversationByIndex(_: *anyopaque, _: usize, _: *weixin_control.Conversation) bool {
    // Real UI-thread pinning is added in the pin/resolver task.
    return false;
}
```

In the `weixin_vtable` literal (after `.inbound_file_dir = wxInboundFileDir,` ~line 5926):

```zig
    .list_ai_conversations = wxListAiConversations,
    .pin_ai_conversation_by_index = wxPinAiConversationByIndex,
```

- [ ] **Step 6: Verify everything compiles + tests pass + Windows cross-compiles**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS (existing tests still green; new fakes compile).

Run: `zig build -Dtarget=x86_64-windows-gnu 2>&1 | tail -20`
Expected: builds (AppWindow stubs compile for Windows).

- [ ] **Step 7: Commit**

```bash
git add src/weixin/control.zig src/weixin/controller.zig src/weixin/agent.zig src/AppWindow.zig
git commit -m "feat(weixin): extend Control vtable with conversation list/pin (stubs)"
```

---

## Task 4: Route /list and /switch in agent.zig

**Files:**
- Modify: `src/weixin/agent.zig` — imports, `route`, helpers, `helpTextConst`, `usageText`, new handler fns, new tests.

- [ ] **Step 1: Write the failing route tests**

Add these tests at the end of `src/weixin/agent.zig` (after the last existing test):

```zig
test "/list shows conversations with current marker and copilot tag" {
    var fake = FakeControl{
        .conv_titles = &.{ "Claude", "zsh ~/p" },
        .conv_models = &.{ "glm-5.2", "opus" },
        .conv_busy = &.{ false, true },
        .conv_copilot = &.{ false, true },
        .conv_current = 0,
    };
    var out = Reply.init(t.allocator);
    defer out.deinit();
    try route(t.allocator, fake.control_iface(), defaultSettings(), "/list", null, &out);
    const s = out.text.items;
    try t.expect(std.mem.indexOf(u8, s, "共 2 个") != null);
    try t.expect(std.mem.indexOf(u8, s, "➤") != null);
    try t.expect(std.mem.indexOf(u8, s, "· 副驾") != null);
    try t.expect(std.mem.indexOf(u8, s, "忙") != null);
}

test "/list with no conversations" {
    var fake = FakeControl{};
    var out = Reply.init(t.allocator);
    defer out.deinit();
    try route(t.allocator, fake.control_iface(), defaultSettings(), "/list", null, &out);
    try t.expect(std.mem.indexOf(u8, out.text.items, "没有副驾会话") != null);
}

test "/switch pins the right conversation and replies with a digest" {
    var fake = FakeControl{ .conv_titles = &.{ "A", "B" }, .conv_models = &.{ "m1", "m2" } };
    var out = Reply.init(t.allocator);
    defer out.deinit();
    try route(t.allocator, fake.control_iface(), defaultSettings(), "/switch 2", null, &out);
    try t.expectEqual(@as(?usize, 1), fake.pin_called_index);
    try t.expect(std.mem.indexOf(u8, out.text.items, "已切换到会话 2：B") != null);
    try t.expect(std.mem.indexOf(u8, out.text.items, "未作为对话上下文") != null);
}

test "/switch out of range does not pin" {
    var fake = FakeControl{ .conv_titles = &.{"A"} };
    var out = Reply.init(t.allocator);
    defer out.deinit();
    try route(t.allocator, fake.control_iface(), defaultSettings(), "/switch 9", null, &out);
    try t.expect(std.mem.indexOf(u8, out.text.items, "无效的会话编号") != null);
    try t.expect(fake.pin_called_index == null);
}

test "/switch non-numeric arg" {
    var fake = FakeControl{ .conv_titles = &.{"A"} };
    var out = Reply.init(t.allocator);
    defer out.deinit();
    try route(t.allocator, fake.control_iface(), defaultSettings(), "/switch abc", null, &out);
    try t.expect(std.mem.indexOf(u8, out.text.items, "无效的会话编号") != null);
}

test "/switch with no argument shows usage" {
    var fake = FakeControl{};
    var out = Reply.init(t.allocator);
    defer out.deinit();
    try route(t.allocator, fake.control_iface(), defaultSettings(), "/switch", null, &out);
    try t.expect(std.mem.indexOf(u8, out.text.items, "用法") != null);
}

test "/sessions, /ls, /use are aliases" {
    var fake = FakeControl{ .conv_titles = &.{ "A", "B" }, .conv_models = &.{ "m1", "m2" } };
    var out = Reply.init(t.allocator);
    defer out.deinit();
    try route(t.allocator, fake.control_iface(), defaultSettings(), "/sessions", null, &out);
    try t.expect(std.mem.indexOf(u8, out.text.items, "共 2 个") != null);

    var out2 = Reply.init(t.allocator);
    defer out2.deinit();
    try route(t.allocator, fake.control_iface(), defaultSettings(), "/use 1", null, &out2);
    try t.expectEqual(@as(?usize, 0), fake.pin_called_index);
}

test "unknown command is still rejected" {
    var fake = FakeControl{};
    var out = Reply.init(t.allocator);
    defer out.deinit();
    try route(t.allocator, fake.control_iface(), defaultSettings(), "/bogus x", null, &out);
    try t.expect(std.mem.indexOf(u8, out.text.items, "未知命令") != null);
}

test "/status reports the current conversation" {
    var fake = FakeControl{
        .conv_titles = &.{ "Claude", "B" },
        .conv_models = &.{ "glm", "m2" },
        .conv_current = 0,
    };
    var out = Reply.init(t.allocator);
    defer out.deinit();
    try route(t.allocator, fake.control_iface(), defaultSettings(), "/status", null, &out);
    try t.expect(std.mem.indexOf(u8, out.text.items, "在线") != null);
    try t.expect(std.mem.indexOf(u8, out.text.items, "Claude") != null);
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `zig build test 2>&1 | tail -30`
Expected: FAIL — `/list` routes to "未知命令", `/switch` etc. not handled; `pin_called_index`/`conv_*` references compile (added in Task 3).

- [ ] **Step 3: Add the import**

In `src/weixin/agent.zig`, after the existing imports (line 6 `const approval_reply = @import("approval_reply.zig");`), add:

```zig
const session_list = @import("session_list.zig");
```

- [ ] **Step 4: Add command-classification helpers**

In `src/weixin/agent.zig`, after `fn isPing` (line 52), add:

```zig
fn isListCommand(cmd: []const u8) bool {
    return eqIgnoreCase(cmd, "/list") or eqIgnoreCase(cmd, "/sessions") or eqIgnoreCase(cmd, "/ls");
}

fn isSwitchCommand(cmd: []const u8) bool {
    return eqIgnoreCase(cmd, "/switch") or eqIgnoreCase(cmd, "/use");
}

fn isKnownCommand(cmd: []const u8) bool {
    return eqIgnoreCase(cmd, "/term") or eqIgnoreCase(cmd, "/keys") or
        eqIgnoreCase(cmd, "/ai") or eqIgnoreCase(cmd, "/stop") or
        isListCommand(cmd) or isSwitchCommand(cmd);
}

/// Commands that are valid with no argument.
fn isNoArgCommand(cmd: []const u8) bool {
    return eqIgnoreCase(cmd, "/stop") or isListCommand(cmd);
}
```

- [ ] **Step 5: Rewrite the gates and dispatch in `route`**

In `src/weixin/agent.zig`, replace the body of `route` from the `/help` line through the final `return sendAi(...)` (lines 71-88) with:

```zig
    if (eqIgnoreCase(cmd, "/help")) return out.set(helpTextConst);
    if (eqIgnoreCase(cmd, "/status")) return statusReply(ctrl, out);
    if (cmd.len != 0 and !isKnownCommand(cmd)) {
        return out.set("未知命令。\n\n" ++ helpTextConst);
    }
    if (cmd.len != 0 and !isNoArgCommand(cmd) and parts.arg.len == 0) {
        return out.set(usageText(cmd));
    }

    if (!ctrl.isConnected()) return out.set("WispTerm 当前离线，无法处理。");

    if (eqIgnoreCase(cmd, "/stop")) return stopAi(ctrl, out);
    if (eqIgnoreCase(cmd, "/term")) return sendTerminal(ctrl, parts.arg, true, out);
    if (eqIgnoreCase(cmd, "/keys")) return sendTerminal(ctrl, parts.arg, false, out);
    if (isListCommand(cmd)) return listConversations(ctrl, out);
    if (isSwitchCommand(cmd)) return switchConversation(ctrl, parts.arg, out);
    if (eqIgnoreCase(cmd, "/ai")) return sendAi(ctrl, parts.arg, reply_context, out);
    return sendAi(ctrl, text, reply_context, out);
```

- [ ] **Step 6: Add the handler functions**

In `src/weixin/agent.zig`, after `fn stopAi` (ends line 148), add:

```zig
fn listConversations(ctrl: control.Control, out: *Reply) !void {
    var list: control.ConversationList = .{};
    ctrl.listAiConversations(&list);
    out.text.clearRetainingCapacity();
    try session_list.writeList(&out.text, out.allocator, list.slice());
}

fn switchConversation(ctrl: control.Control, arg: []const u8, out: *Reply) !void {
    const n = std.fmt.parseInt(usize, arg, 10) catch
        return out.set("无效的会话编号，请先 /list 查看。");
    if (n == 0) return out.set("无效的会话编号，请先 /list 查看。");

    var conv: control.Conversation = .{};
    if (!ctrl.pinAiConversationByIndex(n - 1, &conv))
        return out.set("无效的会话编号，请先 /list 查看。");

    // latestTranscript() now resolves to the just-pinned conversation; take a
    // short UTF-8-safe tail for the digest (borrowed, used immediately).
    const tail = session_list.tailLines(ctrl.latestTranscript(), 6, 600);
    out.text.clearRetainingCapacity();
    try session_list.writeDigest(&out.text, out.allocator, n, conv, tail);
}

fn statusReply(ctrl: control.Control, out: *Reply) !void {
    if (!ctrl.isConnected()) return out.set("微信直连：离线");
    var list: control.ConversationList = .{};
    ctrl.listAiConversations(&list);
    for (list.slice()) |c| {
        if (!c.is_current) continue;
        const tag: []const u8 = if (c.is_copilot) " · 副驾" else "";
        const s = try std.fmt.allocPrint(out.allocator, "微信直连：在线\n当前会话：{s}{s}  [{s}]", .{ c.title(), tag, c.model() });
        defer out.allocator.free(s);
        return out.set(s);
    }
    return out.set("微信直连：在线\n当前会话：默认（发送消息将新建副驾会话）");
}
```

- [ ] **Step 7: Update `helpTextConst` and `usageText`**

Replace `helpTextConst` (lines 160-164) with:

```zig
const helpTextConst =
    "WispTerm 微信直连命令：\n" ++
    "/ping 验证连接\n/status 查看状态\n/list 列出副驾会话\n" ++
    "/switch <编号> 切换并固定会话\n/ai <内容> 发送给副驾\n" ++
    "/stop 停止当前 AI 处理\n/term <命令> 发送到终端并回车\n/keys <文本> 发送原始文本\n" ++
    "普通文本默认发送给当前会话。";
```

Replace `usageText` (lines 170-175) with:

```zig
fn usageText(cmd: []const u8) []const u8 {
    if (eqIgnoreCase(cmd, "/term")) return "用法：/term <命令>";
    if (eqIgnoreCase(cmd, "/keys")) return "用法：/keys <文本>";
    if (eqIgnoreCase(cmd, "/ai")) return "用法：/ai <内容>";
    if (isSwitchCommand(cmd)) return "用法：/switch <会话编号>";
    return helpTextConst;
}
```

Delete the now-unused `statusText` function (lines 166-168) — it is replaced by `statusReply`. Verify no other reference remains:

Run: `grep -n "statusText" src/weixin/agent.zig`
Expected: no matches.

- [ ] **Step 8: Run the tests to verify they pass**

Run: `zig build test 2>&1 | tail -30`
Expected: PASS (all existing + the 9 new tests).

- [ ] **Step 9: Windows cross-compile sanity**

Run: `zig build -Dtarget=x86_64-windows-gnu 2>&1 | tail -10`
Expected: builds.

- [ ] **Step 10: Commit**

```bash
git add src/weixin/agent.zig
git commit -m "feat(weixin): route /list and /switch with digest + status"
```

---

## Task 5: Real pin + resolver + handlers in AppWindow.zig

**Files:**
- Modify: `src/AppWindow.zig` — pin global, `tabConversationSession`, `weixinActiveAiTabIndex`, the five consumers in `handleWeixinControlRequest`, `WeixinRequest` op enum + fields, two op handlers, two real wrappers (replace Task 3 stubs).

No unit tests (GUI/threadlocal state). Gate = build + cross-compile + the pure tests from Tasks 1-4 still green. Runtime behavior is GUI-verified on Windows separately.

- [ ] **Step 1: Add the pin global + conversation-session helper**

In `src/AppWindow.zig`, near the other weixin globals (after `var g_weixin_transcript_owned: []u8 = &.{};` ~line 5689), add:

```zig
/// The AI conversation WeChat is pinned to (independent of the on-screen active
/// tab). UI-thread-only — read/written exclusively inside
/// handleWeixinControlRequest, so no lock is needed. Cleared automatically when
/// its conversation closes (see weixinActiveAiTabIndex).
var g_weixin_pinned_session: ?*ai_chat.Session = null;
```

Immediately before `fn weixinActiveAiTabIndex()` (line 5710), add:

```zig
/// The *ai_chat.Session a tab contributes as its AI conversation, or null:
/// a dedicated AI-chat tab's session, or a terminal tab's Copilot sidebar
/// session (once opened). A tab contributes at most one.
fn tabConversationSession(ts: *tab.TabState) ?*ai_chat.Session {
    if (ts.kind == .ai_chat) return ts.ai_chat_session;
    return ts.copilot_session;
}
```

- [ ] **Step 2: Make the resolver pin-aware**

Replace the body of `weixinActiveAiTabIndex()` (lines 5710-5722) with:

```zig
fn weixinActiveAiTabIndex() ?usize {
    // 1) Honor an explicit WeChat pin if its conversation is still open.
    //    Pointer identity only — never dereference a possibly-stale pointer.
    if (g_weixin_pinned_session) |pinned| {
        for (0..tab.g_tab_count) |i| {
            if (tab.g_tabs[i]) |ts| {
                if (tabConversationSession(ts) == pinned) return i;
            }
        }
        // The pinned conversation was closed: drop the stale pin and fall back.
        g_weixin_pinned_session = null;
    }
    // 2) Default (unchanged): the active tab if it is an AI-chat tab, else the
    //    first AI-chat tab. Copilot sidebars are reachable only via an explicit
    //    /switch pin, not the default.
    if (active_tab_state.g_active_tab < tab.g_tab_count) {
        if (tab.g_tabs[active_tab_state.g_active_tab]) |ts| {
            if (ts.kind == .ai_chat) return active_tab_state.g_active_tab;
        }
    }
    for (0..tab.g_tab_count) |i| {
        if (tab.g_tabs[i]) |ts| {
            if (ts.kind == .ai_chat) return i;
        }
    }
    return null;
}
```

- [ ] **Step 3: Route the five consumers through `tabConversationSession`**

In `handleWeixinControlRequest`:

(a) `.send_input` — the `aichat`-id branch (lines 5783-5796). Replace:

```zig
                if (idx >= tab.g_tab_count) return;
                const tab_state = tab.g_tabs[idx] orelse return;
                if (tab_state.kind != .ai_chat) return;
                const session = tab_state.ai_chat_session orelse return;
```

with:

```zig
                if (idx >= tab.g_tab_count) return;
                const tab_state = tab.g_tabs[idx] orelse return;
                const session = tabConversationSession(tab_state) orelse return;
```

(b) `.latest_transcript` (lines 5801-5808). Replace:

```zig
            const idx = weixinActiveAiTabIndex() orelse return;
            const tab_state = tab.g_tabs[idx] orelse return;
            if (tab_state.kind != .ai_chat) return;
            const session = tab_state.ai_chat_session orelse return;
```

with:

```zig
            const idx = weixinActiveAiTabIndex() orelse return;
            const tab_state = tab.g_tabs[idx] orelse return;
            const session = tabConversationSession(tab_state) orelse return;
```

(c) `.ai_approval_pending` (lines 5809-5815). Replace:

```zig
            const idx = weixinActiveAiTabIndex() orelse return;
            const tab_state = tab.g_tabs[idx] orelse return;
            if (tab_state.kind != .ai_chat) return;
            const session = tab_state.ai_chat_session orelse return;
```

with:

```zig
            const idx = weixinActiveAiTabIndex() orelse return;
            const tab_state = tab.g_tabs[idx] orelse return;
            const session = tabConversationSession(tab_state) orelse return;
```

(d) `.resolve_ai_approval` (lines 5816-5823). Replace:

```zig
            const idx = weixinActiveAiTabIndex() orelse return;
            const tab_state = tab.g_tabs[idx] orelse return;
            if (tab_state.kind != .ai_chat) return;
            const session = tab_state.ai_chat_session orelse return;
```

with:

```zig
            const idx = weixinActiveAiTabIndex() orelse return;
            const tab_state = tab.g_tabs[idx] orelse return;
            const session = tabConversationSession(tab_state) orelse return;
```

(e) `.inbound_file_dir` (lines 5824-5843). Replace the nested block:

```zig
            if (weixinActiveAiTabIndex()) |idx| {
                if (tab.g_tabs[idx]) |tab_state| {
                    if (tab_state.kind == .ai_chat) {
                        if (tab_state.ai_chat_session) |session| {
                            if (session.workingDirOverride()) |w| {
                                req.dir = std.heap.page_allocator.dupe(u8, w) catch return;
                                req.found = true;
                                return;
                            }
                        }
                    }
                }
            }
```

with:

```zig
            if (weixinActiveAiTabIndex()) |idx| {
                if (tab.g_tabs[idx]) |tab_state| {
                    if (tabConversationSession(tab_state)) |session| {
                        if (session.workingDirOverride()) |w| {
                            req.dir = std.heap.page_allocator.dupe(u8, w) catch return;
                            req.found = true;
                            return;
                        }
                    }
                }
            }
```

- [ ] **Step 4: Add the two new ops + fields to `WeixinRequest`**

In the `WeixinRequest` struct (lines 5691-5706), extend the `op` enum and add input/output fields. Change the `op` line to:

```zig
    op: enum { find_ai, find_term, open_ai, send_input, latest_transcript, ai_approval_pending, resolve_ai_approval, inbound_file_dir, list_conversations, pin_by_index },
```

Add these fields (after `approve: bool = false,` ~line 5697):

```zig
    pin_index: usize = 0, // pin_by_index input
    conv_list_out: ?*weixin_control.ConversationList = null, // list_conversations output
    conv_one_out: ?*weixin_control.Conversation = null, // pin_by_index output
```

- [ ] **Step 5: Add the two op handlers**

In the `switch (req.op)` in `handleWeixinControlRequest`, after the `.inbound_file_dir => { ... }` arm (before the closing `}` at line 5844), add:

```zig
        .list_conversations => {
            const out = req.conv_list_out orelse return;
            const cur = weixinActiveAiTabIndex();
            var n: usize = 0;
            for (0..tab.g_tab_count) |i| {
                if (n >= out.items.len) break;
                const ts = tab.g_tabs[i] orelse continue;
                const session = tabConversationSession(ts) orelse continue;
                var c = &out.items[n];
                c.* = .{};
                c.is_copilot = (ts.kind != .ai_chat);
                c.is_current = (cur != null and cur.? == i);
                c.busy = session.request_inflight;
                c.setTitle(ts.getTitle());
                c.setModel(session.model());
                if (session.workingDirOverride()) |w| c.setCwd(w);
                n += 1;
            }
            out.count = n;
            req.found = true;
        },
        .pin_by_index => {
            const out = req.conv_one_out orelse return;
            var n: usize = 0;
            for (0..tab.g_tab_count) |i| {
                const ts = tab.g_tabs[i] orelse continue;
                const session = tabConversationSession(ts) orelse continue;
                if (n == req.pin_index) {
                    g_weixin_pinned_session = session;
                    out.* = .{};
                    out.is_copilot = (ts.kind != .ai_chat);
                    out.is_current = true;
                    out.busy = session.request_inflight;
                    out.setTitle(ts.getTitle());
                    out.setModel(session.model());
                    if (session.workingDirOverride()) |w| out.setCwd(w);
                    req.found = true;
                    return;
                }
                n += 1;
            }
        },
```

- [ ] **Step 6: Replace the stub wrappers with real ones**

Replace the two stub functions added in Task 3 (`wxListAiConversations`, `wxPinAiConversationByIndex`) with:

```zig
fn wxListAiConversations(_: *anyopaque, out: *weixin_control.ConversationList) void {
    out.count = 0;
    var req = WeixinRequest{ .op = .list_conversations, .conv_list_out = out };
    _ = weixinDispatch(&req);
    // On dispatch failure (no UI window) out stays count=0, which is correct.
}

fn wxPinAiConversationByIndex(_: *anyopaque, idx0: usize, out: *weixin_control.Conversation) bool {
    var req = WeixinRequest{ .op = .pin_by_index, .pin_index = idx0, .conv_one_out = out };
    if (!weixinDispatch(&req)) return false;
    return req.found;
}
```

- [ ] **Step 7: Build, test, cross-compile**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS (pure tests unaffected).

Run: `zig build test-full 2>&1 | tail -20`
Expected: PASS.

Run: `zig build -Dtarget=x86_64-windows-gnu 2>&1 | tail -20`
Expected: builds clean (this is the real compile gate for the AppWindow changes — the bridge runs only on Windows).

- [ ] **Step 8: Commit**

```bash
git add src/AppWindow.zig
git commit -m "feat(weixin): pin-aware resolver + conversation list/pin handlers"
```

---

## Task 6: Final verification & docs

- [ ] **Step 1: Full suite green**

Run: `zig build test && zig build test-full && zig build -Dtarget=x86_64-windows-gnu`
Expected: all succeed.

- [ ] **Step 2: Manual grep audit — no consumer left on the old pattern**

Run: `grep -n "kind != .ai_chat\|ai_chat_session orelse return" src/AppWindow.zig`
Expected: only matches outside the weixin `handleWeixinControlRequest` block (e.g. unrelated code). The five weixin consumers should now use `tabConversationSession`.

- [ ] **Step 3: Update the spec status**

Edit `docs/superpowers/specs/2026-06-17-weixin-list-switch-conversations-design.md` header `**Status:**` to `Implemented (Linux suites green; Windows GUI verification pending)`.

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/specs/2026-06-17-weixin-list-switch-conversations-design.md
git commit -m "docs(weixin): mark list/switch design implemented (GUI pending)"
```

- [ ] **Step 5: GUI smoke (Windows, manual — outside this plan's automation)**

The WeChat bridge only runs on Windows with a live binding. Verify on a Windows build:
1. Open ≥2 AI conversations (mix a dedicated AI-chat tab and a terminal-tab Copilot sidebar).
2. From WeChat: `/list` → both appear; the current one has `➤`; the copilot shows `· 副驾`.
3. `/switch 2` → digest arrives (title/model/dir/state + "未作为对话上下文" footer).
4. Send a normal message → it lands in conversation 2, regardless of the on-screen focused tab.
5. Close the pinned conversation on the machine → next WeChat message falls back to the default; `/list` shows the new current target.

---

## Self-review against the spec

- **`/list` (+ `/sessions`/`/ls`)** → Task 4 routing + Task 2 `writeList` + Task 5 `list_conversations` handler. ✓
- **`/switch <n>` (+ `/use`)** → Task 4 routing + Task 5 `pin_by_index` handler + Task 2 `writeDigest`. ✓
- **Independent pin** → Task 5 `g_weixin_pinned_session` + pin-aware resolver; focused tab never touched. ✓
- **Copilot sidebars included** → Task 5 `tabConversationSession` + consumer fallthrough; `is_copilot` tag in formatters. ✓
- **Lightweight digest, not context** → Task 2 `writeDigest` (local fields + transcript tail + "未作为对话上下文" footer), pushed as the `/switch` reply only. ✓
- **Stable identity (not index)** → pin stores `*ai_chat.Session`; resolver scans by pointer identity, auto-clears on close. ✓
- **Default unchanged when unpinned** → resolver step 2 is the original logic, dedicated-AI-tab only. ✓
- **`/status` shows current target** → Task 4 `statusReply`. ✓
- **Edge cases** (offline, no conversations, out-of-range, non-numeric, no-arg usage, stale-pin fallback) → Task 4 tests + Task 5 resolver. ✓
- **TDD + FakeControl** → Tasks 1-4 are test-first; Task 5 is GUI-only (cross-compile gate). ✓

**Placeholder scan:** none — every code step shows complete code.

**Type consistency:** `Conversation`/`ConversationList` (Task 1) used identically in `control.zig` vtable (Task 3), `session_list.zig` (Task 2), `agent.zig` (Task 4), and AppWindow handlers (Task 5). Method names `listAiConversations`/`pinAiConversationByIndex`/`tabConversationSession`/`setTitle`/`setModel`/`setCwd`/`request_inflight`/`workingDirOverride`/`model`/`getTitle` are consistent across tasks. Vtable field names `list_ai_conversations`/`pin_ai_conversation_by_index` match in all four implementors.
