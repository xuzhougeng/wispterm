# AI Copilot Sidebar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a right-side, keyboard-toggled AI copilot sidebar that auto-targets the currently focused terminal, so users get an in-context assistant without opening a separate AI Agent tab or picking the wrong terminal.

**Architecture:** A new pure `ai_sidebar.zig` module owns visibility + width + layout math (mirrors `browser_panel`'s right-dock model). Per-tab conversations live in a new `TabState.copilot_session` field, reusing the existing `ai_chat.Session` engine, ToolHost, and renderer. The chat renderer is rect-parameterized so the same draw code serves both the full AI-chat tab and the narrow right panel. The copilot request pre-targets the focused surface (via `write_context_surface_id`) and attaches a per-message lightweight terminal snapshot. Only one right panel is visible at a time (mutual-exclusion arbiter in `AppWindow`).

**Tech Stack:** Zig, custom GL renderer, libghostty-vt. Tests via `zig build test` (fast native logic) and `zig build test-full` (complete suite).

**Reference spec:** `docs/superpowers/specs/2026-05-30-ai-copilot-sidebar-design.md`

**Branch:** `feat/ai-copilot-sidebar` (already created; the spec commit lives here).

---

## Conventions for every task

- Run fast logic tests with: `zig build test`
- Run the complete suite with: `zig build test-full -Dtarget=x86_64-windows-gnu`
  - Green baseline is **497/499** (1 known Windows-API failure + 1 skip). Do not expect 499/499.
- A new `_ = @import("...")` line is required in `src/test_fast.zig` (fast) and/or `src/test_main.zig` (full) for a module's `test {}` blocks to run at all. **Tests in an unreferenced module silently do not run.**
- Commit after each task with a conventional-commit message (`feat(ai-copilot): ...`), ending with the Co-Authored-By trailer the repo uses.

---

## Phase 1 — `ai_sidebar` state + layout module (pure, fast-testable)

### Task 1: Create the pure `ai_sidebar` module

**Files:**
- Create: `src/ai_sidebar.zig`
- Modify: `src/test_fast.zig` (register import)

This module is intentionally **free of `tab`/`AppWindow` imports** so its math runs in the fast suite. The "only show on terminal tabs" gating lives in `AppWindow` (Phase 8), not here.

- [ ] **Step 1: Write `src/ai_sidebar.zig` with state, math, and tests**

```zig
//! State and layout math for the right-side AI copilot sidebar.
//!
//! Mirrors browser_panel's right-dock width model, but the conversation lives
//! per-tab in TabState.copilot_session — this module owns only visibility and
//! width. Kept free of tab/AppWindow imports so the math runs in the fast test
//! suite; the "only on terminal tabs" gate is applied by the caller (AppWindow).

const std = @import("std");

pub const DEFAULT_WIDTH: f32 = 480;
pub const MIN_WIDTH: f32 = 320;
pub const MAX_WIDTH: f32 = 1200;
pub const MIN_CONTENT_WIDTH: f32 = 320;
pub const RESIZE_HIT_WIDTH: f32 = 12;

pub const Bounds = struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
};

/// Global visibility flag (the active terminal tab's session is what renders).
pub threadlocal var g_visible: bool = false;
/// Shared width across tabs; not persisted across restarts (design decision).
pub threadlocal var g_width: f32 = DEFAULT_WIDTH;

pub fn maxWidthForWindow(window_width: f32) f32 {
    return @max(MIN_WIDTH, @min(MAX_WIDTH, window_width - MIN_CONTENT_WIDTH));
}

/// Set the panel width, clamped to [MIN_WIDTH, maxWidthForWindow]. Returns true
/// if the value changed.
pub fn setWidth(w: f32, window_width: f32) bool {
    const next = @max(MIN_WIDTH, @min(maxWidthForWindow(window_width), w));
    if (next == g_width) return false;
    g_width = next;
    return true;
}

/// Width the panel should occupy for a given window, leaving MIN_CONTENT_WIDTH
/// for the terminal. Assumes the panel is visible; the caller gates visibility.
pub fn panelWidthForWindow(window_width: i32, left_offset: f32, right_offset: f32) f32 {
    const win_w: f32 = @floatFromInt(window_width);
    const max_width = @max(MIN_WIDTH, @min(MAX_WIDTH, win_w - left_offset - right_offset - MIN_CONTENT_WIDTH));
    return @max(MIN_WIDTH, @min(g_width, max_width));
}

/// Pixel bounds of the panel (right-docked). Assumes visible; caller gates.
pub fn boundsForWindow(window_width: i32, window_height: i32, titlebar_height: f32, left_offset: f32, right_offset: f32) Bounds {
    const win_w: f32 = @floatFromInt(window_width);
    const win_h: f32 = @floatFromInt(window_height);
    const panel_w = panelWidthForWindow(window_width, left_offset, right_offset);
    const right = @max(0, win_w - right_offset);
    const left = @max(left_offset, right - panel_w);
    const top = @max(0, titlebar_height);
    const bottom = @max(top, win_h);
    return .{
        .left = @intFromFloat(@round(left)),
        .top = @intFromFloat(@round(top)),
        .right = @intFromFloat(@round(right)),
        .bottom = @intFromFloat(@round(bottom)),
    };
}

pub fn show() void {
    g_visible = true;
}
pub fn hide() void {
    g_visible = false;
}
pub fn toggle() void {
    g_visible = !g_visible;
}

test "panelWidthForWindow clamps to g_width when it fits" {
    g_width = 480;
    try std.testing.expectApproxEqAbs(@as(f32, 480), panelWidthForWindow(1600, 0, 0), 0.001);
}

test "panelWidthForWindow shrinks to keep MIN_CONTENT_WIDTH" {
    g_width = 1200;
    // 800 - 0 - 0 - 320 = 480 available; clamped down from 1200.
    try std.testing.expectApproxEqAbs(@as(f32, 480), panelWidthForWindow(800, 0, 0), 0.001);
}

test "panelWidthForWindow never goes below MIN_WIDTH" {
    g_width = 320;
    // Even a tiny window keeps at least MIN_WIDTH.
    try std.testing.expectApproxEqAbs(MIN_WIDTH, panelWidthForWindow(300, 0, 0), 0.001);
}

test "setWidth clamps and reports change" {
    g_width = DEFAULT_WIDTH;
    try std.testing.expect(setWidth(10_000, 1600)); // clamped to maxWidthForWindow, changed
    try std.testing.expectApproxEqAbs(maxWidthForWindow(1600), g_width, 0.001);
    try std.testing.expect(!setWidth(g_width, 1600)); // no change
    g_width = DEFAULT_WIDTH; // restore for other tests
}

test "boundsForWindow right-docks the panel" {
    g_width = 480;
    const b = boundsForWindow(1600, 900, 30, 0, 0);
    try std.testing.expectEqual(@as(i32, 1600), b.right);
    try std.testing.expectEqual(@as(i32, 1120), b.left); // 1600 - 480
    try std.testing.expectEqual(@as(i32, 30), b.top);
    try std.testing.expectEqual(@as(i32, 900), b.bottom);
}

test "toggle flips visibility" {
    g_visible = false;
    toggle();
    try std.testing.expect(g_visible);
    toggle();
    try std.testing.expect(!g_visible);
}
```

- [ ] **Step 2: Register the module in the fast test suite**

In `src/test_fast.zig`, inside the `test {}` block, add after the `_ = @import("ai_chat_layout.zig");` line:

```zig
    _ = @import("ai_sidebar.zig");
```

- [ ] **Step 3: Run the tests, expect PASS**

Run: `zig build test`
Expected: build succeeds; all `ai_sidebar` tests pass.

- [ ] **Step 4: Commit**

```bash
git add src/ai_sidebar.zig src/test_fast.zig
git commit -m "feat(ai-copilot): add ai_sidebar state + layout module"
```

---

## Phase 2 — Keybind action (`toggle_ai_copilot`)

### Task 2: Wire `Ctrl+Shift+A` → `toggle_ai_copilot` through the action pipeline

The pipeline is: `keybind.Action` → `command_dispatch.Command` (via `resolve`) → `input.executeCommand`. The effect function (`AppWindow.toggleAiCopilot`) is implemented in Phase 8; here we add the plumbing and its unit test.

**Files:**
- Modify: `src/keybind.zig:58` (Action enum) and `src/keybind.zig:399` (default_bindings)
- Modify: `src/input/command_dispatch.zig` (Command union + resolve + test)
- Modify: `src/input.zig:966` (executeCommand switch)

- [ ] **Step 1: Add the failing command_dispatch test**

In `src/input/command_dispatch.zig`, add this test at the end of the file:

```zig
test "toggle_ai_copilot resolves in the early phase" {
    try std.testing.expectEqual(Command.toggle_ai_copilot, resolve(.toggle_ai_copilot, .early).?);
    try std.testing.expectEqual(@as(?Command, null), resolve(.toggle_ai_copilot, .late));
}
```

- [ ] **Step 2: Run it, expect FAIL (compile error: no enum field)**

Run: `zig build test`
Expected: FAIL — `error: no field named 'toggle_ai_copilot'`.

- [ ] **Step 3: Add `toggle_ai_copilot` to `keybind.Action`**

In `src/keybind.zig`, in the `pub const Action = enum {` block (starts at line 58), add the new variant next to the other toggles (e.g. after `toggle_sidebar,`):

```zig
    toggle_ai_copilot,
```

- [ ] **Step 4: Add the default binding `Ctrl+Shift+A`**

In `src/keybind.zig`, in `pub const default_bindings = [_]Binding{` (line 399), add after the `toggle_sidebar` binding line:

```zig
    .{ .trigger = .{ .mods = .{ .ctrl = true, .shift = true }, .key_code = 'A' }, .action = .toggle_ai_copilot },
```

(macOS remaps Ctrl→Cmd automatically via the existing loop in `Set.defaults()`.)

- [ ] **Step 5: Add the Command variant + resolve mapping**

In `src/input/command_dispatch.zig`, add to the `Command` union (in the "Early commands" group, e.g. after `toggle_sidebar,`):

```zig
    toggle_ai_copilot,
```

Then in `resolve`'s `.early` switch (after the `.toggle_sidebar => .toggle_sidebar,` arm):

```zig
            .toggle_ai_copilot => .toggle_ai_copilot,
```

- [ ] **Step 6: Add the executeCommand arm (calls the Phase-8 effect)**

In `src/input.zig`, in `executeCommand` (line 966), add to the Early group (after `.toggle_sidebar => toggleSidebar(),`):

```zig
        .toggle_ai_copilot => AppWindow.toggleAiCopilot(),
```

Add a temporary stub so this compiles before Phase 8. In `src/AppWindow.zig`, near `pub fn leftPanelsWidth()` (line 634), add:

```zig
pub fn toggleAiCopilot() void {
    // Implemented in Phase 8 (arbiter + focus). Stub keeps the build green.
    ai_sidebar.toggle();
}
```

And add the import at the top of `src/AppWindow.zig` alongside the other panel imports (near where `browser_panel` is imported):

```zig
const ai_sidebar = @import("ai_sidebar.zig");
```

- [ ] **Step 7: Run tests, expect PASS**

Run: `zig build test`
Expected: PASS, including the new command_dispatch test.

- [ ] **Step 8: Commit**

```bash
git add src/keybind.zig src/input/command_dispatch.zig src/input.zig src/AppWindow.zig
git commit -m "feat(ai-copilot): add toggle_ai_copilot action (Ctrl+Shift+A)"
```

---

## Phase 3 — Per-tab copilot session storage

### Task 3: Add `copilot_session` to `TabState` and free it on tab close

**Files:**
- Modify: `src/appwindow/tab.zig:40-88` (TabState struct + deinit)

- [ ] **Step 1: Add the field**

In `src/appwindow/tab.zig`, in `pub const TabState = struct {` (line 40), add after `ai_chat_session: ?*ai_chat.Session = null,`:

```zig
    /// Copilot conversation for a terminal tab (Issue #98). Distinct from
    /// `ai_chat_session`, which backs a dedicated AI-chat tab. Lazily created
    /// the first time the copilot sidebar is opened on this tab.
    copilot_session: ?*ai_chat.Session = null,
```

- [ ] **Step 2: Free it in deinit's `.terminal` branch**

In `TabState.deinit` (line 76), change the `.terminal` arm from:

```zig
            .terminal => self.tree.deinit(),
```

to:

```zig
            .terminal => {
                self.tree.deinit();
                if (self.copilot_session) |session| {
                    session.deinit();
                    self.copilot_session = null;
                }
            },
```

- [ ] **Step 3: Add a lazy accessor for the active terminal tab's copilot session**

Still in `src/appwindow/tab.zig`, add near the existing `pub fn activeAiChat()` (find it with `grep -n "pub fn activeAiChat" src/appwindow/tab.zig`):

```zig
/// Get (creating if needed) the copilot session for the active terminal tab.
/// Returns null on non-terminal tabs or if creation fails. `make` builds a
/// fresh Session (AppWindow supplies it so this module stays UI-free).
pub fn activeCopilotSession(
    make: *const fn () ?*ai_chat.Session,
) ?*ai_chat.Session {
    const t = activeTab() orelse return null;
    if (t.kind != .terminal) return null;
    if (t.copilot_session == null) {
        t.copilot_session = make() orelse return null;
    }
    return t.copilot_session;
}
```

- [ ] **Step 4: Build to confirm it compiles**

Run: `zig build test`
Expected: PASS (no behavior change yet; this is a struct/field addition).

- [ ] **Step 5: Commit**

```bash
git add src/appwindow/tab.zig
git commit -m "feat(ai-copilot): store per-tab copilot session in TabState"
```

---

## Phase 4 — Copilot request targeting (default to focused surface)

### Task 4: Add copilot mode + bound-surface fields to `Session` and pre-target the request

**Files:**
- Modify: `src/ai_chat.zig:704` (Session fields + setter), `:2192` (buildRequestLocked), `:3331-3380` (exec tool fallback)

**Background (verified):** `terminal_select` calls `setWriteContext(request, id)`; the getter is `selectedWriteContext(request)` (`src/ai_chat.zig:4266`). Exec tools (`ssh_session_exec`, `wsl_session_exec`, `terminal_repl_exec`) currently hard-require `surface_id` ("Missing surface_id", lines ~3345-3375). We make copilot requests (a) pre-seed the write-context to the bound surface and (b) fall back to it when the model omits `surface_id`.

- [ ] **Step 1: Add Session fields + setter**

In `src/ai_chat.zig`, in `pub const Session = struct {` (after the `approval_*` fields, ~line 763), add:

```zig
    /// Copilot mode: when true, requests pre-target the bound surface and exec
    /// tools fall back to it when the model omits surface_id (Issue #98).
    copilot: bool = false,
    bound_surface_id_buf: [16]u8 = undefined,
    bound_surface_id_len: usize = 0,
```

Add a setter method to `Session` (next to `setHistoryChangeHook`, ~line 782):

```zig
    pub fn setBoundSurface(self: *Session, surface_id: []const u8) void {
        const n = @min(surface_id.len, self.bound_surface_id_buf.len);
        @memcpy(self.bound_surface_id_buf[0..n], surface_id[0..n]);
        self.bound_surface_id_len = n;
    }

    pub fn boundSurfaceId(self: *const Session) []const u8 {
        return self.bound_surface_id_buf[0..self.bound_surface_id_len];
    }
```

- [ ] **Step 2: Copy copilot flag into the request + pre-seed write-context**

`ChatRequest` (line 244) already has `write_context_surface_id` + `_len`. Add a `copilot` flag to the struct (after `agent_enabled: bool,`):

```zig
    copilot: bool = false,
```

In `buildRequestLocked` (line 2192), in the `req.* = .{ ... }` initializer (line 2262), add:

```zig
            .copilot = self.copilot,
```

Then, immediately after the initializer block (after the `reasoning_effort_owned = false;` line at 2284, before `return req;`), add:

```zig
        if (self.copilot and self.bound_surface_id_len > 0) {
            setWriteContext(req, self.boundSurfaceId());
        }
```

- [ ] **Step 3: Add the failing test for write-context pre-seeding**

In `src/ai_chat.zig`, near the existing write-context tests (`grep -n "write_context_surface_id\\[0..request" src/ai_chat.zig` → ~5891), add:

```zig
test "copilot session pre-targets the bound surface in its request" {
    const session = try Session.init(
        std.testing.allocator,
        "copilot", "", "", "", "", "", "", "", "",
    );
    defer session.deinit();
    session.copilot = true;
    session.setBoundSurface("abc123");

    const req = try session.buildRequestLocked();
    defer req.deinit();

    try std.testing.expectEqualStrings("abc123", req.write_context_surface_id[0..req.write_context_surface_id_len]);
}
```

(If `buildRequestLocked` is private to `Session`, this test is inside `ai_chat.zig` so it has access. Confirm `req.deinit()` is the correct teardown by checking the `ChatRequest.deinit` signature at `src/ai_chat.zig:264`.)

- [ ] **Step 4: Register `ai_chat.zig` tests run + run them**

`ai_chat.zig` tests run via `test-full` (it pulls the heavy graph). Confirm it is imported in `src/test_main.zig` (`grep -n 'ai_chat.zig' src/test_main.zig`). Run:

Run: `zig build test-full -Dtarget=x86_64-windows-gnu 2>&1 | grep -iE "copilot|passed|failed"`
Expected: the new test passes; overall 497/499 baseline holds (the 1 known failure is unrelated Windows API).

- [ ] **Step 5: Exec-tool fallback to the bound surface when surface_id omitted**

In `src/ai_chat.zig` `executeToolCall` (line 3331), for each of `ssh_session_exec`, `wsl_session_exec`, `terminal_repl_exec`, replace the hard requirement. Current pattern (line ~3359):

```zig
        const surface_id = jsonStringArg(args.value, "surface_id") orelse return request.allocator.dupe(u8, "Missing surface_id");
```

Change to (do this for all three exec tools):

```zig
        const surface_id = jsonStringArg(args.value, "surface_id") orelse defaultExecSurfaceId(request) orelse return request.allocator.dupe(u8, "Missing surface_id");
```

Add the helper near `selectedWriteContext` (~line 4266):

```zig
/// Copilot fallback: when an exec tool omits surface_id, use the request's
/// pre-seeded write-context (the bound/focused terminal). Non-copilot requests
/// keep the original "Missing surface_id" behavior.
fn defaultExecSurfaceId(request: *const ChatRequest) ?[]const u8 {
    if (!request.copilot) return null;
    if (request.write_context_surface_id_len == 0) return null;
    return request.write_context_surface_id[0..request.write_context_surface_id_len];
}
```

- [ ] **Step 6: Build the full suite, expect baseline green**

Run: `zig build test-full -Dtarget=x86_64-windows-gnu`
Expected: 497/499.

- [ ] **Step 7: Commit**

```bash
git add src/ai_chat.zig
git commit -m "feat(ai-copilot): pre-target focused surface for copilot requests"
```

---

## Phase 5 — Per-message lightweight terminal snapshot

### Task 5: Inject `cwd + last ~40 lines` of the bound surface into each copilot request

**Files:**
- Modify: `src/ai_chat.zig` (new `buildCopilotContext` helper + injection in `buildRequestLocked`)

- [ ] **Step 1: Add the pure context-builder with a failing test**

In `src/ai_chat.zig`, add a constant near the other limits and a builder function:

```zig
pub const COPILOT_CONTEXT_LINES: usize = 40;

/// Build the per-message copilot context block from a full surface snapshot:
/// the cwd plus the last COPILOT_CONTEXT_LINES non-empty-trailing lines.
/// Returns an owned slice the caller frees.
fn buildCopilotContext(allocator: std.mem.Allocator, cwd: []const u8, snapshot: []const u8) ![]u8 {
    const trimmed = std.mem.trimRight(u8, snapshot, "\n");
    // Walk back to keep only the last COPILOT_CONTEXT_LINES lines.
    var start: usize = trimmed.len;
    var newlines: usize = 0;
    while (start > 0) {
        const c = trimmed[start - 1];
        if (c == '\n') {
            newlines += 1;
            if (newlines > COPILOT_CONTEXT_LINES) break;
        }
        start -= 1;
    }
    const tail = trimmed[start..];
    return std.fmt.allocPrint(
        allocator,
        "[wispterm current terminal]\ncwd: {s}\nrecent output:\n{s}",
        .{ cwd, tail },
    );
}

test "buildCopilotContext keeps cwd and the last N lines" {
    const snap = "l1\nl2\nl3\nl4\nl5\n";
    const out = try buildCopilotContext(std.testing.allocator, "/home/u", snap);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "cwd: /home/u") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "l5") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "l1") != null); // only 5 lines, under the cap
}

test "buildCopilotContext truncates to the last COPILOT_CONTEXT_LINES" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    var i: usize = 0;
    while (i < 100) : (i += 1) try buf.print(std.testing.allocator, "line{d}\n", .{i});
    const out = try buildCopilotContext(std.testing.allocator, "/x", buf.items);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "line99") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "line0\n") == null); // dropped
}
```

- [ ] **Step 2: Run, expect FAIL then PASS**

Run: `zig build test-full -Dtarget=x86_64-windows-gnu 2>&1 | grep -iE "buildCopilotContext|passed|failed"`
Expected: after adding the function the two tests pass.

- [ ] **Step 3: Inject the context into copilot requests**

In `buildRequestLocked` (line 2192): after `tool_snapshot` is collected (line 2244) and the `messages` array is filled, append the copilot context as a trailing system-style message **only for copilot requests**. Because `messages` is pre-sized to `visible_count`, allocate one extra slot when copilot context applies.

Concretely, change the `messages` allocation (line 2208) to reserve the extra slot:

```zig
        const copilot_extra: usize = if (self.copilot and self.bound_surface_id_len > 0) 1 else 0;
        const messages = try self.allocator.alloc(RequestMessage, visible_count + copilot_extra);
```

Then, after the message-copy loop (after line 2232) and after `tool_snapshot` is available (move the injection to just before `req.* = .{...}`), add:

```zig
        if (copilot_extra == 1) {
            if (tool_snapshot) |snap| {
                if (findSurface(snap, self.boundSurfaceId())) |surface| {
                    const ctx = try buildCopilotContext(self.allocator, surface.cwd, surface.snapshot);
                    defer self.allocator.free(ctx);
                    messages[written] = try requestMessageWithClonedFields(self.allocator, .user, ctx, null, null, null);
                    written += 1;
                }
            }
        }
```

Note: `findSurface(snapshot, id)` already exists (used by `terminalSelectTool`, `src/ai_chat.zig:3578`). If the bound surface is not in the snapshot (closed), the context is simply omitted — graceful degradation. Verify `requestMessageWithClonedFields`'s parameter order against its definition (`grep -n "fn requestMessageWithClonedFields" src/ai_chat.zig`) and adjust the call if the signature differs; the role must be `.user` and the body the `ctx` string.

Also: the extra slot is only consumed when the surface is found. If it is not found, `messages` has one unused trailing slot — that breaks the `messages[0..written]` invariant only if downstream code uses `messages.len`. Check how `req.messages` is consumed; if it iterates the full slice, instead size the slice to `written` by re-slicing before assigning: set `.messages = messages[0..written]` in the initializer and free the full backing allocation in `ChatRequest.deinit`. Prefer the simplest correct option: build messages into a `std.ArrayListUnmanaged(RequestMessage)` and `toOwnedSlice` — confirm the existing deinit frees a slice (it does: `self.allocator.free(self.messages)` at line ~268).

- [ ] **Step 4: Build full suite, expect baseline green**

Run: `zig build test-full -Dtarget=x86_64-windows-gnu`
Expected: 497/499.

- [ ] **Step 5: Commit**

```bash
git add src/ai_chat.zig
git commit -m "feat(ai-copilot): attach lightweight terminal snapshot per message"
```

---

## Phase 6 — Copilot system prompt variant

### Task 6: Give copilot sessions a prompt that says "you are bound to the current terminal"

**Files:**
- Modify: `src/platform/agent_prompt.zig` (add a copilot prompt constant)
- Modify: `src/ai_chat.zig` (expose + select it for copilot sessions)

- [ ] **Step 1: Inspect the existing prompt**

Run: `grep -n "defaultSystemPrompt" src/platform/agent_prompt.zig`
Read the existing `defaultSystemPrompt` to match tone/structure.

- [ ] **Step 2: Add a copilot prompt constant**

In `src/platform/agent_prompt.zig`, add a `copilotSystemPrompt` constant. It should reuse the same tool guidance but prepend a binding clause. Minimal viable addition (adjust wording to match the existing prompt's voice):

```zig
pub const copilotSystemPrompt = defaultSystemPrompt ++
    "\n\nYou are the in-context copilot for the user's CURRENTLY FOCUSED terminal. " ++
    "Default every terminal action to that terminal — you do not need terminal_list " ++
    "or terminal_select first, and may omit surface_id (it resolves to the focused " ++
    "terminal). Only call terminal_list/terminal_select when the user explicitly " ++
    "asks you to act on a different terminal or server. Each message includes a " ++
    "lightweight snapshot (cwd + recent output) of that terminal.";
```

- [ ] **Step 3: Expose it from ai_chat and add a content test**

In `src/ai_chat.zig`, near `pub const DEFAULT_SYSTEM_PROMPT` (line 27):

```zig
pub const COPILOT_SYSTEM_PROMPT = platform_agent_prompt.copilotSystemPrompt;
```

Add a test near the existing prompt tests (~line 5232):

```zig
test "copilot prompt keeps tool guidance and adds the binding clause" {
    try std.testing.expect(std.mem.indexOf(u8, COPILOT_SYSTEM_PROMPT, "currently focused") != null or
        std.mem.indexOf(u8, COPILOT_SYSTEM_PROMPT, "CURRENTLY FOCUSED") != null);
    try std.testing.expect(std.mem.indexOf(u8, COPILOT_SYSTEM_PROMPT, "ssh_session_exec") != null);
    try std.testing.expect(std.mem.indexOf(u8, COPILOT_SYSTEM_PROMPT, "terminal_select") != null);
}
```

- [ ] **Step 4: Run full suite**

Run: `zig build test-full -Dtarget=x86_64-windows-gnu`
Expected: 497/499, new prompt test passes.

- [ ] **Step 5: Commit**

```bash
git add src/platform/agent_prompt.zig src/ai_chat.zig
git commit -m "feat(ai-copilot): add copilot-variant system prompt"
```

---

## Phase 7 — Rect-parameterize the chat renderer

### Task 7: Make `ai_chat_renderer` draw at an explicit `(chat_x, chat_w)` instead of deriving from panel widths

**Files:**
- Modify: `src/renderer/ai_chat_renderer.zig` (all functions that compute `x`/`w` from `left_panels_w`/`right_panels_w`)
- Modify: `src/AppWindow.zig:562-579` (the single existing caller, `renderAiChatFrame`)
- Modify: `src/input.zig` (hit-test callers pass `chat_x`/`chat_w` — see Phase 9; in this task only keep them compiling)

**Why:** Every renderer function currently derives its rect identically:

```zig
    const x = @round(left_panels_w);
    const w = @round(@max(1.0, window_width - left_panels_w - right_panels_w));
```

(confirmed at lines 129-130, 337-338, 416-417, 495-496, 509-510, 534-535, 548-549, and more). To host the chat in a right panel, these must accept the rect explicitly.

- [ ] **Step 1: Enumerate the functions to change**

Run: `grep -nE "left_panels_w: f32|x = @round\(left_panels_w\)" src/renderer/ai_chat_renderer.zig`
List every `pub fn` (and private fn) that takes `left_panels_w`/`right_panels_w`.

- [ ] **Step 2: Apply the mechanical signature change to each function**

For each function, replace the parameter pair:

```zig
    left_panels_w: f32,
    right_panels_w: f32,
```

with:

```zig
    chat_x: f32,
    chat_w: f32,
```

and replace the body derivation:

```zig
    const x = @round(left_panels_w);
    const w = @round(@max(1.0, window_width - left_panels_w - right_panels_w));
```

with:

```zig
    const x = @round(chat_x);
    const w = @round(@max(1.0, chat_w));
```

Leave everything downstream of `x`/`w` unchanged.

- [ ] **Step 3: Update the existing caller to preserve current behavior**

In `src/AppWindow.zig` `renderAiChatFrame` (line 562), compute the content-region rect and pass it. Change the body so it still derives the full-tab rect from panel widths:

```zig
fn renderAiChatFrame(fb_width: c_int, fb_height: c_int, titlebar_offset: f32, left_panels_w: f32, right_panels_w: f32) void {
    gpu.state.setViewport(0, 0, @intCast(fb_width), @intCast(fb_height));
    gpu.gl_init.setProjection(@floatFromInt(fb_width), @floatFromInt(fb_height));
    clearWithBackground(fb_width, fb_height);
    titlebar.renderTitlebar(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
    titlebar.renderSidebar(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
    markdown_preview_renderer.render(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset, 0);
    file_explorer_renderer.render(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
    if (activeAiChat()) |session| {
        const chat_x = left_panels_w;
        const chat_w = @as(f32, @floatFromInt(fb_width)) - left_panels_w - right_panels_w;
        ai_chat_renderer.render(session, @floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset, chat_x, chat_w);
    }
}
```

- [ ] **Step 4: Fix the other callers so it compiles**

Other callers live in `src/input.zig` (hit tests: `inputFieldMetricsAt`, `transcriptScrollbarHitTest`, `stopButtonHitTest`, etc.) and in `ai_chat_renderer` itself. For each call site flagged by the build error, pass the same `(chat_x, chat_w)` the function previously received as `(left_panels_w, right_panels_w)` — for now wire `chat_x = left_panels_w`, `chat_w = window_width - left_panels_w - right_panels_w` at the call site so behavior is unchanged. (Phase 9 switches the copilot path to the sidebar rect.)

Iterate: `zig build 2>&1 | head -40` and fix each reported call until it compiles.

- [ ] **Step 5: Build and manually verify the AI-chat tab is unchanged**

Run: `zig build` (release-safe local build) then launch and open an AI Agent tab.
Expected: the full-tab AI chat renders and behaves exactly as before (no visual shift, hit tests still work).

- [ ] **Step 6: Run full suite**

Run: `zig build test-full -Dtarget=x86_64-windows-gnu`
Expected: 497/499 (this is a non-behavioral refactor; `ai_chat_layout.zig` pure tests still pass).

- [ ] **Step 7: Commit**

```bash
git add src/renderer/ai_chat_renderer.zig src/AppWindow.zig src/input.zig
git commit -m "refactor(ai-chat): rect-parameterize chat renderer (chat_x/chat_w)"
```

---

## Phase 8 — Render the copilot into the right panel + toggle behavior

### Task 8: Layout integration, mutual-exclusion arbiter, render call, and focus

**Files:**
- Modify: `src/AppWindow.zig` (`rightPanelsWidth`, `rightPanelsWidthForWindow`, `toggleAiCopilot`, a `renderAiCopilotPanel` helper, and the two terminal render paths at ~1432 and ~3909)

- [ ] **Step 1: Add visibility gate + width helpers**

In `src/AppWindow.zig`, add near `leftPanelsWidth()` (line 634):

```zig
pub fn aiCopilotVisible() bool {
    return ai_sidebar.g_visible and isActiveTabTerminal();
}

pub fn aiCopilotWidth(window_width: i32) f32 {
    if (!aiCopilotVisible()) return 0;
    return ai_sidebar.panelWidthForWindow(window_width, leftPanelsWidth(), 0);
}
```

- [ ] **Step 2: Include copilot width in the right-panel total**

`rightPanelsWidth()` (line 638) has no window width; the copilot's clamp needs one. Use the window-aware path. Update `rightPanelsWidthForWindow` (line 642) to add the copilot width:

```zig
pub fn rightPanelsWidthForWindow(window_width: i32) f32 {
    const preview_w = markdown_preview_panel.width();
    const browser_w = browser_panel.panelWidthForWindow(window_width, leftPanelsWidth(), preview_w);
    return preview_w + browser_w + aiCopilotWidth(window_width);
}
```

Because the arbiter (Step 3) guarantees only one right panel is visible, `browser_w` and the copilot width are never both nonzero. For the no-arg `rightPanelsWidth()` (line 638) used by render-frame callers, add the copilot's raw width when visible:

```zig
pub fn rightPanelsWidth() f32 {
    const copilot_w = if (aiCopilotVisible()) ai_sidebar.g_width else 0;
    return markdown_preview_panel.width() + browser_panel.width() + copilot_w;
}
```

- [ ] **Step 3: Implement the mutual-exclusion arbiter + real toggle**

Replace the Phase-2 stub `toggleAiCopilot` with:

```zig
pub fn toggleAiCopilot() void {
    if (!isActiveTabTerminal()) return; // copilot is terminal-only
    if (ai_sidebar.g_visible) {
        ai_sidebar.hide();
        focusActiveTerminal();
        g_force_rebuild = true;
        g_cells_valid = false;
        return;
    }
    // Exclusive right slot: close the other right panels first.
    browser_panel.close();
    markdownPreviewHide(); // see Step 4
    ai_sidebar.show();
    // Ensure the active terminal tab has a session and focus its input.
    _ = ensureActiveCopilotSession();
    input.focusAiCopilot(); // see Phase 9
    g_force_rebuild = true;
    g_cells_valid = false;
}
```

- [ ] **Step 4: Add the session factory and markdown-hide shim**

Find the markdown preview panel's hide/close function: `grep -nE "pub fn (hide|close|toggle)" src/markdown_preview_panel.zig`. Add a thin wrapper `markdownPreviewHide()` in AppWindow calling it (or call it directly if it takes no args).

Add `ensureActiveCopilotSession`, which builds a copilot `ai_chat.Session` from the default AI profile and binds it to the focused surface:

```zig
fn makeCopilotSession() ?*ai_chat.Session {
    const allocator = g_allocator orelse return null;
    // Reuse the same default AI profile the Agent uses. Find the existing
    // profile-load helper (grep AppWindow/overlays for how AI Agent tabs build
    // their Session — e.g. `openDefaultAgentSession`). Mirror it but set
    // copilot mode + the copilot system prompt.
    const profile = loadDefaultAiProfile(allocator) orelse return null; // existing helper
    const session = ai_chat.Session.initWithProtocol(
        allocator,
        "Copilot",
        profile.base_url,
        profile.api_key,
        profile.model,
        profile.protocol,
        ai_chat.COPILOT_SYSTEM_PROMPT,
        profile.thinking,
        profile.reasoning_effort,
        profile.stream,
        "true", // agent_enabled
    ) catch return null;
    session.copilot = true;
    return session;
}

fn ensureActiveCopilotSession() ?*ai_chat.Session {
    const session = tab.activeCopilotSession(makeCopilotSession) orelse return null;
    if (g_agent_context_surface_id_len > 0) {
        session.setBoundSurface(g_agent_context_surface_id[0..g_agent_context_surface_id_len]);
    }
    return session;
}
```

**Note:** locate the real default-profile loader the AI Agent tab uses (`grep -rn "openDefaultAgentSession\|ai_profiles\|loadDefault" src/`) and adapt `makeCopilotSession` to it. The field names above (`profile.base_url`, etc.) are illustrative — match the actual profile struct. The required deltas vs. the Agent path are only: name `"Copilot"`, system prompt `COPILOT_SYSTEM_PROMPT`, and `session.copilot = true`.

- [ ] **Step 5: Refresh the bound surface as focus changes**

In `syncActiveSurfaceCaches` (line 738) — which already updates `g_agent_context_surface_id` — also refresh the active tab's copilot binding so the copilot retargets when the user switches split focus. After the existing `@memcpy(g_agent_context_surface_id...)` block, add:

```zig
        if (tab.activeTab()) |t| {
            if (t.kind == .terminal) {
                if (t.copilot_session) |session| session.setBoundSurface(s.remote_id[0..]);
            }
        }
```

- [ ] **Step 6: Add the copilot render helper and call it from the terminal paths**

Add a helper modeled on `renderAiChatFrame` but drawing only the chat into the sidebar rect:

```zig
fn renderAiCopilotPanel(fb_width: c_int, fb_height: c_int, titlebar_offset: f32) void {
    if (!aiCopilotVisible()) return;
    const session = ensureActiveCopilotSession() orelse return;
    const left = leftPanelsWidth();
    const bounds = ai_sidebar.boundsForWindow(@intCast(fb_width), @intCast(fb_height), titlebar_offset, left, 0);
    const chat_x: f32 = @floatFromInt(bounds.left);
    const chat_w: f32 = @floatFromInt(bounds.right - bounds.left);
    ai_chat_renderer.render(session, @floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset, chat_x, chat_w);
}
```

Call `renderAiCopilotPanel(fb_width, fb_height, titlebar_offset);` at the END of each terminal render path — i.e. in the `else if (activeSurface())` branch that begins at line 1433, after the terminal + panels have been drawn, and in the multi-split path near line 3909 (the sibling of the other `renderAiChatFrame` call). Confirm both terminal paths reserve content width using `rightPanelsWidth()`/`rightPanelsWidthForWindow()` (they already subtract `right_panels_w` when computing `content_w` at line 1421) so the terminal shrinks to make room.

- [ ] **Step 7: Build + manual verification**

Run: `zig build`, launch, open a terminal tab, press `Ctrl+Shift+A`.
Expected: a right panel appears with the copilot chat; the terminal narrows; pressing again hides it. Open the browser panel — it should close the copilot, and vice versa (mutual exclusion). Switching to another terminal tab shows that tab's own (empty or separate) conversation.

- [ ] **Step 8: Run full suite**

Run: `zig build test-full -Dtarget=x86_64-windows-gnu`
Expected: 497/499.

- [ ] **Step 9: Commit**

```bash
git add src/AppWindow.zig
git commit -m "feat(ai-copilot): render copilot in right panel with exclusive slot"
```

---

## Phase 9 — Route input to the copilot panel

### Task 9: Send keyboard/mouse to the copilot session when it is visible and focused

**Files:**
- Modify: `src/input.zig` (focus state, key/char routing, mouse hit tests offset by the sidebar rect)

**Context:** Input already routes to `AppWindow.activeAiChat()` for the AI-chat tab (e.g. paste at `src/input.zig:982`, scroll/hit-test helpers throughout). The copilot needs a parallel "is the copilot focused?" path that targets the active tab's `copilot_session` and uses the sidebar's `(chat_x, chat_w)` for hit testing.

- [ ] **Step 1: Add copilot focus state + accessor**

In `src/input.zig`, add a thread-local focus flag and helpers:

```zig
threadlocal var g_ai_copilot_focused: bool = false;

pub fn focusAiCopilot() void {
    g_ai_copilot_focused = true;
}

pub fn blurAiCopilot() void {
    g_ai_copilot_focused = false;
}

fn activeCopilotSession() ?*AppWindow.ai_chat.Session {
    if (!AppWindow.aiCopilotVisible() or !g_ai_copilot_focused) return null;
    return AppWindow.activeCopilotSessionForInput(); // thin getter: tab.activeTab().?.copilot_session
}
```

Add `pub fn activeCopilotSessionForInput() ?*ai_chat.Session` to `AppWindow.zig` returning `if (aiCopilotVisible()) (tab.activeTab() orelse null).?.copilot_session else null` (guard the optional access).

- [ ] **Step 2: Route character + key input**

In `handleChar`/`handleKey` (the functions that already special-case the AI-chat tab — `grep -n "fn handleChar\|fn handleKey\|activeAiChat" src/input.zig`), add an early branch: if `activeCopilotSession()` is non-null, forward to `session.handleChar(cp)` / `session.handleKeyWithWrapCols(ev, cols)` and `session.submit()` on Enter, then return (consume). Compute `cols` via `AppWindow.ai_chat_renderer.inputWrapColumns(panel_w)` where `panel_w = AppWindow.aiCopilotWidth(window_width)`.

`Esc` handling: if the copilot has an in-flight request, forward `Esc` to stop it (mirror the AI-chat tab's stop path); otherwise `blurAiCopilot()` + `AppWindow.toggleAiCopilot()` to hide and return focus to the terminal.

- [ ] **Step 3: Offset mouse hit tests by the sidebar rect**

The mouse hit-test calls in `src/input.zig` (lines ~2448-2666, 3011-3132, 3396) pass `(left_panels_w, panel_w)` derived for the full-tab chat. For copilot clicks, pass the sidebar rect instead: `chat_x = ai_sidebar.boundsForWindow(...).left`, `chat_w = aiCopilotWidth(window_width)`. Gate on `activeCopilotSession()` so terminal-tab mouse handling is unaffected when the copilot is closed/unfocused. Click inside the sidebar rect → keep `g_ai_copilot_focused = true`; click in the terminal area → `blurAiCopilot()` and let the terminal handle it.

This is the largest input edit. Work incrementally: route keyboard first (Step 2), verify typing/submit works, then add mouse (scroll, transcript selection, stop button, permission chip) one hit-test at a time, building between each.

- [ ] **Step 4: Build + manual verification**

Run: `zig build`, launch, open a terminal, `Ctrl+Shift+A`, type a question, Enter.
Expected: the message sends; the model's first action targets the current terminal without a `terminal_select` round-trip; scrolling, selecting answer text, copy, and the Stop button work inside the panel; `Esc` stops an in-flight request, and `Esc` again (idle) hides the panel and returns focus to the terminal.

- [ ] **Step 5: Run full suite**

Run: `zig build test-full -Dtarget=x86_64-windows-gnu`
Expected: 497/499.

- [ ] **Step 6: Commit**

```bash
git add src/input.zig src/AppWindow.zig
git commit -m "feat(ai-copilot): route keyboard and mouse input to the copilot panel"
```

---

## Phase 10 — Resize grip, docs, and final verification

### Task 10: Add the resize grip, document the feature, verify end-to-end

**Files:**
- Modify: `src/input.zig` (resize grip drag, mirror browser panel's `RESIZE_HIT_WIDTH` + `setWidth`)
- Modify: `docs/ai-agent.md` (new "In-context Copilot Sidebar" section)
- Modify: `README.md` (keyboard table: add `Ctrl+Shift+A` toggle)

- [ ] **Step 1: Add the resize grip**

Mirror `browser_panel`'s resize handling: detect hover/drag within `ai_sidebar.RESIZE_HIT_WIDTH` of the panel's left edge (`ai_sidebar.boundsForWindow(...).left`), and on drag call `ai_sidebar.setWidth(new_width, window_width)` then force a rebuild. Find the browser panel's resize logic for the exact pattern: `grep -nE "RESIZE_HIT_WIDTH|resize|setWidth" src/input.zig`.

- [ ] **Step 2: Document in `docs/ai-agent.md`**

Add a section after "AI Chat Sessions" describing: `Ctrl+Shift+A` toggles a right-side copilot bound to the focused terminal; per-tab conversations; defaults all terminal actions to the current terminal; shares the default AI profile; exclusive with the browser/preview panels.

- [ ] **Step 3: Update the README keyboard table**

In `README.md`, add a row to the shortcuts table:

```text
| Toggle AI Copilot sidebar (current terminal) | **Ctrl+Shift+A** | **Cmd+Shift+A** |
```

- [ ] **Step 4: Full manual verification checklist**

Build and run; confirm each:
- Toggle on/off with `Ctrl+Shift+A` on a terminal tab; no-op on an AI Agent tab.
- Opening the copilot closes the browser/preview panel and vice versa.
- Per-tab: tab A and tab B have independent conversations; closing tab A frees its conversation (no leak — run a debug build and watch for `session.deinit`).
- Ask "what's in this directory?" — the model runs `ls`/`dir` on the focused terminal directly (no `terminal_list`/`terminal_select`).
- Split the terminal, move focus, send a message — it targets the newly focused pane.
- Resize the panel by dragging its left edge; width persists across tab switches but resets on restart.
- `Esc` stops an in-flight request; `Esc` when idle hides the panel.

- [ ] **Step 5: Run the complete suite**

Run: `zig build test-full -Dtarget=x86_64-windows-gnu`
Expected: 497/499 baseline.

- [ ] **Step 6: Commit + open PR**

```bash
git add docs/ai-agent.md README.md src/input.zig
git commit -m "docs(ai-copilot): document copilot sidebar + add resize grip"
git push -u origin feat/ai-copilot-sidebar
gh pr create --title "feat: in-context AI copilot sidebar (#98)" --body "Implements the right-side AI copilot from the design spec. Closes #98."
```

---

## Self-review notes (coverage vs. spec)

- §3 会话模型 (per-tab) → Task 3 (`copilot_session` in TabState) + Task 8 Step 5 (rebind on focus change).
- §3 互斥单槽 → Task 8 Step 3 arbiter.
- §3 工具范围 (full tools, default to current) → Task 4 (pre-target + exec fallback) + Task 6 (prompt).
- §3 上下文注入 (hybrid, cwd + ~40 lines) → Task 5.
- §3 会话存储 (new `copilot_session` field) → Task 3.
- §3 AI Profile (shared default) → Task 8 Step 4 (`makeCopilotSession`).
- §3 开关键 `Ctrl+Shift+A` → Task 2.
- §3 宽度 (shared, not persisted) → Task 1 (`g_width`) + Task 10 (resize grip).
- §6 渲染/输入 → Task 7 (rect-parameterize) + Task 8 (render) + Task 9 (input).
- §5.5 降级 → Task 5 Step 3 (missing surface → omit context) + Task 3 Step 2 (free on close) + Task 9 Step 2 (Esc cancel).
- §7 测试 → Tasks 1,2,4,5,6 carry unit tests; UI integration (7,8,9,10) uses build + manual verification, consistent with how this GL codebase tests rendering.

**Known soft spots for the implementer to resolve against live code (not placeholders, but verify signatures):**
- `requestMessageWithClonedFields` parameter order (Task 5 Step 3).
- The real default-AI-profile loader used by AI Agent tabs (Task 8 Step 4) — match its struct field names.
- The markdown preview panel's hide/close function name (Task 8 Step 4).
- The two terminal render-path call sites (Task 8 Step 6) — confirm both at ~line 1433 and ~line 3909.
