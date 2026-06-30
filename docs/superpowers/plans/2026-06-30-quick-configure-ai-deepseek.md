# Quick Configure AI (DeepSeek) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a command-palette command `Settings: Quick Configure AI` that opens a guided overlay where the user pastes one DeepSeek API key, verifies it against `GET /models`, and on success auto-creates two profiles (`DeepSeek`=`deepseek-v4-pro` as main, `DeepSeek Flash`=`deepseek-v4-flash` as subagent) sharing that key.

**Architecture:** Mirror the existing Feishu config form (command + session-launcher-hosted overlay). Add one genuinely new piece: an async verify channel. Because `g_overlay_state` is `threadlocal`, the worker thread must NOT touch overlay state — it only does the network call, records the result into a non-threadlocal mutex-guarded channel, and calls an injected wake callback (`window_backend.postWakeup`). The main loop drains the channel each frame (`tickQuickAiVerify`, called next to `tickSessionLauncher`) and does all persistence + UI (`setConfigValue`, `saveProfiles`, toast, close) on the main thread.

**Tech Stack:** Zig, `std.http.Client` (mirrors `src/assistant/conversation/request.zig`), existing `profile_codec` / `assistant_profile_store` / `Config.setConfigValue` / `platform/open_url.zig` / `platform/window_backend.zig`.

## Global Constraints

- **Profile names / models (verbatim):** main profile `DeepSeek` model `deepseek-v4-pro`; subagent profile `DeepSeek Flash` model `deepseek-v4-flash`; base URL `https://api.deepseek.com`; protocol `chat_completions`.
- **Tutorial URL placeholder (verbatim):** `https://github.com/xuzhougeng/wispterm/wiki/AI-Copilot-zh` — keep as a single named constant.
- **Register URL (verbatim):** `https://platform.deepseek.com`.
- **Config keys (verbatim):** `ai-default-profile` = `DeepSeek`; `ai-subagent-profile` = `DeepSeek Flash`.
- **Thread rule:** the verify worker thread touches ONLY `std`, the non-threadlocal verify channel, and the injected wake callback. It never reads/writes `g_overlay_state`, toasts, or visibility flags. All `setConfigValue` / `saveProfiles` / toast / overlay-close happen on the main thread.
- **Security:** never log the API key; render the key field masked (`•`); never prefill the key; never store the key in any error/status string.
- **Verify endpoint:** `GET {base_url}/models` with header `Authorization: Bearer <key>`. 200 → ok; 401/403 → invalid key; anything else / network error → network error.
- **Verification commands (this repo; macOS):**
  - Fast unit tests: `zig build test`
  - Native macOS full suite: `zig build test-full -Dtarget=aarch64-macos`
  - App compile/build: `zig build macos-app -Dtarget=aarch64-macos`
  - Format check: `zig fmt --check build.zig src`
  - NOTE: bare `zig build` / `zig build test-full` default to a Windows target and only compile-check; always pass `-Dtarget=aarch64-macos` to actually run native tests.

---

### Task 1: Pure module `quick_ai_config.zig` (form state + profile upsert)

**Files:**
- Create: `src/renderer/overlays/quick_ai_config.zig`
- Modify: `src/test_fast.zig` (add one import line after line 166)
- Test: same file (`test` blocks run in the fast suite once imported)

**Interfaces:**
- Consumes: `profile_codec.AiProfile`, `profile_codec.AiField`, `profile_codec.aiProfileField`, `profile_codec.setProfileDefault` (all in `src/renderer/overlays/profile_codec.zig`).
- Produces (used by later tasks):
  - constants `KEY_FIELD_MAX`, `ROW_OPEN_REGISTER`/`ROW_OPEN_TUTORIAL`/`ROW_KEY`/`ROW_VERIFY`/`ROW_COUNT`, `REGISTER_URL`, `TUTORIAL_URL`, `BASE_URL`, `MAIN_PROFILE_NAME`, `MAIN_MODEL`, `SUB_PROFILE_NAME`, `SUB_MODEL`
  - `VerifyStatus = enum { idle, verifying, ok, empty, invalid, network }`
  - `State` with `key() []const u8`, `append([]const u8)`, `backspace()`, `reset()`, `focusNextRow()`, `focusPrevRow()`, field `focus: usize`, field `status: VerifyStatus`
  - `upsertProfiles(profiles: []profile_codec.AiProfile, count: usize, api_key: []const u8) usize`

- [ ] **Step 1: Create the file with constants, State, and upsert logic**

Create `src/renderer/overlays/quick_ai_config.zig`:

```zig
//! Pure state + logic for the "Quick Configure AI" overlay: the single-key form
//! state, the DeepSeek constants, and the two-profile upsert. No I/O, no threads,
//! no drawing — those live in overlays.zig / quick_verify.zig so this stays
//! unit-tested in the fast suite.
const std = @import("std");
const profile_codec = @import("profile_codec.zig");

const AiProfile = profile_codec.AiProfile;

pub const KEY_FIELD_MAX: usize = 256;

// Form rows: 0 = open register page, 1 = open tutorial page, 2 = API key field, 3 = Verify.
pub const ROW_OPEN_REGISTER: usize = 0;
pub const ROW_OPEN_TUTORIAL: usize = 1;
pub const ROW_KEY: usize = 2;
pub const ROW_VERIFY: usize = 3;
pub const ROW_COUNT: usize = 4;

pub const REGISTER_URL = "https://platform.deepseek.com";
// Placeholder: wiki has no DeepSeek section yet. Change this one line when it does.
pub const TUTORIAL_URL = "https://github.com/xuzhougeng/wispterm/wiki/AI-Copilot-zh";
pub const BASE_URL = "https://api.deepseek.com";

pub const MAIN_PROFILE_NAME = "DeepSeek";
pub const MAIN_MODEL = "deepseek-v4-pro";
pub const SUB_PROFILE_NAME = "DeepSeek Flash";
pub const SUB_MODEL = "deepseek-v4-flash";

pub const VerifyStatus = enum { idle, verifying, ok, empty, invalid, network };

pub const State = struct {
    key_buf: [KEY_FIELD_MAX]u8 = undefined,
    key_len: usize = 0,
    focus: usize = ROW_KEY,
    status: VerifyStatus = .idle,

    pub fn reset(self: *State) void {
        self.key_len = 0;
        self.focus = ROW_KEY;
        self.status = .idle;
    }

    pub fn key(self: *const State) []const u8 {
        return self.key_buf[0..self.key_len];
    }

    pub fn append(self: *State, bytes: []const u8) void {
        for (bytes) |b| {
            if (self.key_len >= KEY_FIELD_MAX) return; // truncate, no overflow
            self.key_buf[self.key_len] = b;
            self.key_len += 1;
        }
    }

    pub fn backspace(self: *State) void {
        if (self.key_len == 0) return;
        var n = self.key_len - 1;
        while (n > 0 and (self.key_buf[n] & 0xC0) == 0x80) : (n -= 1) {} // back one UTF-8 codepoint
        self.key_len = n;
    }

    pub fn focusNextRow(self: *State) void {
        if (self.focus < ROW_COUNT - 1) self.focus += 1;
    }

    pub fn focusPrevRow(self: *State) void {
        if (self.focus > 0) self.focus -= 1;
    }
};

fn indexByName(profiles: []const AiProfile, count: usize, name: []const u8) ?usize {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (std.mem.eql(u8, profile_codec.aiProfileField(&profiles[i], .name), name)) return i;
    }
    return null;
}

fn writeConnectionFields(p: *AiProfile, name: []const u8, model: []const u8, api_key: []const u8) void {
    profile_codec.setProfileDefault(p, .name, name);
    profile_codec.setProfileDefault(p, .base_url, BASE_URL);
    profile_codec.setProfileDefault(p, .api_key, api_key);
    profile_codec.setProfileDefault(p, .model, model);
    profile_codec.setProfileDefault(p, .protocol, "chat_completions");
}

fn fillNewProfileDefaults(p: *AiProfile) void {
    profile_codec.setProfileDefault(p, .thinking, "enabled");
    profile_codec.setProfileDefault(p, .reasoning_effort, "high");
    profile_codec.setProfileDefault(p, .stream, "false");
    profile_codec.setProfileDefault(p, .agent, "true");
    profile_codec.setProfileDefault(p, .max_tokens, "8192");
    profile_codec.setProfileDefault(p, .vision, "off");
}

fn upsertOne(profiles: []AiProfile, count: usize, name: []const u8, model: []const u8, api_key: []const u8) usize {
    if (indexByName(profiles, count, name)) |idx| {
        writeConnectionFields(&profiles[idx], name, model, api_key); // keep other fields as-is
        return count;
    }
    if (count >= profiles.len) return count; // store full — skip rather than overflow
    profiles[count] = .{};
    writeConnectionFields(&profiles[count], name, model, api_key);
    fillNewProfileDefaults(&profiles[count]);
    return count + 1;
}

/// Upsert the two DeepSeek quick-config profiles by name into `profiles[0..count]`.
/// Existing same-named profiles have only their connection fields refreshed; new
/// ones are appended with documented defaults. Returns the new count.
pub fn upsertProfiles(profiles: []AiProfile, count: usize, api_key: []const u8) usize {
    var n = upsertOne(profiles, count, MAIN_PROFILE_NAME, MAIN_MODEL, api_key);
    n = upsertOne(profiles, n, SUB_PROFILE_NAME, SUB_MODEL, api_key);
    return n;
}
```

- [ ] **Step 2: Add the unit tests at the bottom of the same file**

Append to `src/renderer/overlays/quick_ai_config.zig`:

```zig
test "State: append, key, backspace, reset" {
    var s = State{};
    s.append("sk-abc");
    try std.testing.expectEqualStrings("sk-abc", s.key());
    s.backspace();
    try std.testing.expectEqualStrings("sk-ab", s.key());
    s.reset();
    try std.testing.expectEqualStrings("", s.key());
    try std.testing.expectEqual(ROW_KEY, s.focus);
    try std.testing.expectEqual(VerifyStatus.idle, s.status);
}

test "State: append truncates at KEY_FIELD_MAX without overflow" {
    var s = State{};
    const big = "x" ** (KEY_FIELD_MAX + 40);
    s.append(big);
    try std.testing.expectEqual(KEY_FIELD_MAX, s.key().len);
}

test "State: backspace drops a whole multibyte codepoint" {
    var s = State{};
    s.append("a\u{4f60}"); // "a你"
    s.backspace();
    try std.testing.expectEqualStrings("a", s.key());
}

test "State: focus navigation clamps within rows" {
    var s = State{};
    s.focus = ROW_OPEN_REGISTER;
    s.focusPrevRow();
    try std.testing.expectEqual(ROW_OPEN_REGISTER, s.focus);
    s.focusNextRow();
    s.focusNextRow();
    s.focusNextRow();
    try std.testing.expectEqual(ROW_VERIFY, s.focus);
    s.focusNextRow();
    try std.testing.expectEqual(ROW_VERIFY, s.focus);
}

test "upsertProfiles: appends two profiles into an empty store" {
    const profiles = try std.testing.allocator.alloc(AiProfile, 8);
    defer std.testing.allocator.free(profiles);
    const n = upsertProfiles(profiles, 0, "sk-key-1");
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("DeepSeek", profile_codec.aiProfileField(&profiles[0], .name));
    try std.testing.expectEqualStrings("deepseek-v4-pro", profile_codec.aiProfileField(&profiles[0], .model));
    try std.testing.expectEqualStrings("https://api.deepseek.com", profile_codec.aiProfileField(&profiles[0], .base_url));
    try std.testing.expectEqualStrings("sk-key-1", profile_codec.aiProfileField(&profiles[0], .api_key));
    try std.testing.expectEqualStrings("chat_completions", profile_codec.aiProfileField(&profiles[0], .protocol));
    try std.testing.expectEqualStrings("DeepSeek Flash", profile_codec.aiProfileField(&profiles[1], .name));
    try std.testing.expectEqualStrings("deepseek-v4-flash", profile_codec.aiProfileField(&profiles[1], .model));
    try std.testing.expectEqualStrings("true", profile_codec.aiProfileField(&profiles[1], .agent));
}

test "upsertProfiles: updates an existing same-named profile in place" {
    const profiles = try std.testing.allocator.alloc(AiProfile, 8);
    defer std.testing.allocator.free(profiles);
    // Seed an existing "DeepSeek" profile with an old key and a custom system prompt.
    profiles[0] = .{};
    profile_codec.setProfileDefault(&profiles[0], .name, "DeepSeek");
    profile_codec.setProfileDefault(&profiles[0], .api_key, "sk-old");
    profile_codec.setProfileDefault(&profiles[0], .system_prompt, "keep me");
    const n = upsertProfiles(profiles, 1, "sk-new");
    try std.testing.expectEqual(@as(usize, 2), n); // DeepSeek updated, DeepSeek Flash appended
    try std.testing.expectEqualStrings("sk-new", profile_codec.aiProfileField(&profiles[0], .api_key));
    try std.testing.expectEqualStrings("deepseek-v4-pro", profile_codec.aiProfileField(&profiles[0], .model));
    try std.testing.expectEqualStrings("keep me", profile_codec.aiProfileField(&profiles[0], .system_prompt)); // preserved
}
```

- [ ] **Step 3: Wire the file into the fast test suite**

In `src/test_fast.zig`, after line 166 (`_ = @import("renderer/overlays/feishu_config.zig");`), add:

```zig
    _ = @import("renderer/overlays/quick_ai_config.zig");
```

- [ ] **Step 4: Run the fast suite — expect PASS**

Run: `zig build test`
Expected: builds and all tests pass, including the six new `quick_ai_config` tests. (If you run before Step 1/2 are complete, the build fails with `quick_ai_config has no member ...` — that is the expected red.)

- [ ] **Step 5: Format check + commit**

Run: `zig fmt --check build.zig src` (expect: clean)

```bash
git add src/renderer/overlays/quick_ai_config.zig src/test_fast.zig
git commit -m "feat(ai): pure quick-configure form state + DeepSeek profile upsert"
```

---

### Task 2: Verify worker `quick_verify.zig` (async GET /models channel)

**Files:**
- Create: `src/assistant/quick_verify.zig`
- Modify: `src/test_fast.zig` (add one import line after the Task 1 import)
- Test: same file

**Interfaces:**
- Consumes: nothing from earlier tasks (std only); a wake callback supplied by the caller.
- Produces (used by overlays in Tasks 5–6):
  - `Outcome = enum { ok, invalid_key, network_error }`
  - `WakeFn = *const fn () void`
  - `start(base_url: []const u8, api_key: []const u8, wake: WakeFn) bool` — returns false if a verify is already in flight
  - `take() ?Outcome` — main-thread one-shot consume of a finished result

- [ ] **Step 1: Create the file (channel + worker + classify)**

Create `src/assistant/quick_verify.zig`:

```zig
//! Async DeepSeek API-key verification for the Quick Configure AI overlay.
//! The worker thread does ONLY the network call + records into the
//! non-threadlocal channel below + calls the injected wake callback. It never
//! touches overlay state (that is threadlocal to the UI thread). The main loop
//! drains the result with `take()`.
const std = @import("std");

pub const Outcome = enum { ok, invalid_key, network_error };

pub fn classify(status: u16) Outcome {
    return switch (status) {
        200 => .ok,
        401, 403 => .invalid_key,
        else => .network_error,
    };
}

// --- Non-threadlocal worker<->main channel (the ONLY shared cross-thread state) ---
var g_mutex: std.Thread.Mutex = .{};
var g_inflight: bool = false;
var g_done: bool = false;
var g_outcome: Outcome = .network_error;

fn beginInflight() bool {
    g_mutex.lock();
    defer g_mutex.unlock();
    if (g_inflight) return false;
    g_inflight = true;
    g_done = false;
    return true;
}

fn record(outcome: Outcome) void {
    g_mutex.lock();
    defer g_mutex.unlock();
    g_outcome = outcome;
    g_done = true;
    g_inflight = false;
}

/// Main thread: consume a finished result exactly once; null if none/still running.
pub fn take() ?Outcome {
    g_mutex.lock();
    defer g_mutex.unlock();
    if (!g_done) return null;
    g_done = false;
    return g_outcome;
}

pub const WakeFn = *const fn () void;

const Ctx = struct {
    base_url: []const u8, // static caller constant — not freed
    key: []u8, // heap copy owned by the worker
    wake: WakeFn,
};

fn verify(base_url: []const u8, api_key: []const u8) Outcome {
    const a = std.heap.c_allocator;
    const endpoint = std.fmt.allocPrint(a, "{s}/models", .{base_url}) catch return .network_error;
    defer a.free(endpoint);
    const bearer = std.fmt.allocPrint(a, "Bearer {s}", .{api_key}) catch return .network_error;
    defer a.free(bearer);

    var client: std.http.Client = .{ .allocator = a, .write_buffer_size = 16384 };
    defer client.deinit();
    var sink: std.Io.Writer.Allocating = .init(a);
    defer sink.deinit();

    const result = client.fetch(.{
        .location = .{ .url = endpoint },
        .method = .GET,
        .headers = .{ .authorization = .{ .override = bearer } },
        .response_writer = &sink.writer,
    }) catch return .network_error;

    const code: u16 = @intFromEnum(result.status);
    return classify(code);
}

fn worker(ctx: *Ctx) void {
    defer {
        std.heap.c_allocator.free(ctx.key);
        std.heap.c_allocator.destroy(ctx);
    }
    record(verify(ctx.base_url, ctx.key));
    ctx.wake();
}

/// Main thread: start a background verification. `base_url` must be a static
/// constant (not freed); `api_key` is copied. Returns false if already running.
pub fn start(base_url: []const u8, api_key: []const u8, wake: WakeFn) bool {
    if (!beginInflight()) return false;
    const a = std.heap.c_allocator;
    const key_copy = a.dupe(u8, api_key) catch {
        record(.network_error);
        return true;
    };
    const ctx = a.create(Ctx) catch {
        a.free(key_copy);
        record(.network_error);
        return true;
    };
    ctx.* = .{ .base_url = base_url, .key = key_copy, .wake = wake };
    const thread = std.Thread.spawn(.{}, worker, .{ctx}) catch {
        a.free(key_copy);
        a.destroy(ctx);
        record(.network_error);
        return true;
    };
    thread.detach();
    return true;
}
```

- [ ] **Step 2: Add tests (classify + channel mechanics, no network)**

Append to `src/assistant/quick_verify.zig`:

```zig
test "classify maps status codes to outcomes" {
    try std.testing.expectEqual(Outcome.ok, classify(200));
    try std.testing.expectEqual(Outcome.invalid_key, classify(401));
    try std.testing.expectEqual(Outcome.invalid_key, classify(403));
    try std.testing.expectEqual(Outcome.network_error, classify(500));
    try std.testing.expectEqual(Outcome.network_error, classify(0));
}

test "channel: take returns a recorded outcome exactly once, inflight guards" {
    g_mutex.lock();
    g_inflight = false;
    g_done = false;
    g_mutex.unlock();

    try std.testing.expect(take() == null);
    try std.testing.expect(beginInflight());
    try std.testing.expect(!beginInflight()); // already in flight
    record(.ok);
    try std.testing.expectEqual(Outcome.ok, take().?);
    try std.testing.expect(take() == null); // consumed
}
```

- [ ] **Step 3: Wire into the fast suite (compile + run the channel tests)**

In `src/test_fast.zig`, directly after the Task 1 line `_ = @import("renderer/overlays/quick_ai_config.zig");`, add:

```zig
    _ = @import("assistant/quick_verify.zig");
```

- [ ] **Step 4: Run the fast suite — expect PASS**

Run: `zig build test`
Expected: builds (this compiles the `std.http` worker path too) and all tests pass, including the two new `quick_verify` tests.

- [ ] **Step 5: Format check + commit**

Run: `zig fmt --check build.zig src` (expect: clean)

```bash
git add src/assistant/quick_verify.zig src/test_fast.zig
git commit -m "feat(ai): async DeepSeek key verify channel (GET /models worker)"
```

---

### Task 3: Overlay state wrapper `QuickAiFormState`

**Files:**
- Modify: `src/renderer/overlays/state.zig` (add import + struct + `OverlayState` field, mirroring `FeishuFormState` at line 23 and its `feishu` field at line 35)
- Test: same file

**Interfaces:**
- Consumes: `quick_ai_config.State` (Task 1).
- Produces: `OverlayState.quick_ai: QuickAiFormState` with `.config: quick_ai_config.State` and `.visible: bool`.

- [ ] **Step 1: Add the import near the other overlay-module imports at the top of `state.zig`**

```zig
const quick_ai_config = @import("quick_ai_config.zig");
```

- [ ] **Step 2: Add the wrapper struct next to `FeishuFormState` (around line 23)**

```zig
pub const QuickAiFormState = struct {
    config: quick_ai_config.State = .{},
    visible: bool = false,
};
```

- [ ] **Step 3: Add the field to `OverlayState` next to `feishu:` (around line 35)**

```zig
    quick_ai: QuickAiFormState = .{},
```

- [ ] **Step 4: Add a default-state test at the bottom of `state.zig`**

```zig
test "quick ai form defaults hidden and idle" {
    const s = QuickAiFormState{};
    try std.testing.expect(!s.visible);
    try std.testing.expectEqual(quick_ai_config.VerifyStatus.idle, s.config.status);
}
```

- [ ] **Step 5: Run + commit**

Run: `zig build test` (expect: PASS — `state.zig` is already imported by the fast suite)
Run: `zig fmt --check build.zig src` (expect: clean)

```bash
git add src/renderer/overlays/state.zig
git commit -m "feat(ai): QuickAiFormState in overlay state"
```

---

### Task 4: i18n strings for the overlay (form + toast)

**Files:**
- Modify: `src/i18n.zig` — add fields to the `Strings` struct (near `feishu_form_title` at line 239) and a value to EVERY language literal (today there are two: EN near line 466, ZH near line 693 — find them all by searching for `.feishu_form_title =`).

**Interfaces:**
- Produces: new `i18n.s()` fields used by overlays (Tasks 5–6): `quick_ai_form_title`, `quick_ai_intro`, `quick_ai_register_row`, `quick_ai_tutorial_row`, `quick_ai_verify_row`, `quick_ai_status_idle`, `quick_ai_status_verifying`, `quick_ai_status_empty`, `quick_ai_status_invalid`, `quick_ai_status_network`, `toast_quick_ai_done`.

> The `Strings` struct has no defaults, so every language literal MUST set every field or the build fails with "missing struct field". That compile error is your checklist for finding all language tables.

- [ ] **Step 1: Add the field declarations to the `Strings` struct (after `feishu_form_title: []const u8,`)**

```zig
    quick_ai_form_title: []const u8,
    quick_ai_intro: []const u8,
    quick_ai_register_row: []const u8,
    quick_ai_tutorial_row: []const u8,
    quick_ai_verify_row: []const u8,
    quick_ai_status_idle: []const u8,
    quick_ai_status_verifying: []const u8,
    quick_ai_status_empty: []const u8,
    quick_ai_status_invalid: []const u8,
    quick_ai_status_network: []const u8,
    toast_quick_ai_done: []const u8,
```

- [ ] **Step 2: Add the English values to the EN literal (next to its `.feishu_form_title = ...`)**

```zig
    .quick_ai_form_title = "Quick Configure AI",
    .quick_ai_intro = "Paste your DeepSeek API key to set up the main and subagent models.",
    .quick_ai_register_row = "1. Register at platform.deepseek.com  (Enter to open)",
    .quick_ai_tutorial_row = "2. Open the setup guide  (Enter to open)",
    .quick_ai_verify_row = "Verify & Save",
    .quick_ai_status_idle = "Paste your API key, then Verify.",
    .quick_ai_status_verifying = "Verifying…",
    .quick_ai_status_empty = "Paste an API key first.",
    .quick_ai_status_invalid = "Invalid API key — check it and retry.",
    .quick_ai_status_network = "Network error — check your connection and retry.",
    .toast_quick_ai_done = "AI configured — DeepSeek is ready.",
```

- [ ] **Step 3: Add the Chinese values to the ZH literal (next to its `.feishu_form_title = ...`)**

```zig
    .quick_ai_form_title = "快速配置 AI",
    .quick_ai_intro = "粘贴 DeepSeek API key，自动配好主模型和 subagent。",
    .quick_ai_register_row = "1. 去 platform.deepseek.com 注册（回车打开）",
    .quick_ai_tutorial_row = "2. 打开配置教程（回车打开）",
    .quick_ai_verify_row = "校验并保存",
    .quick_ai_status_idle = "粘贴 API key 后点校验。",
    .quick_ai_status_verifying = "校验中…",
    .quick_ai_status_empty = "请先粘贴 API Key。",
    .quick_ai_status_invalid = "API key 无效，请检查后重试。",
    .quick_ai_status_network = "网络错误，请检查网络后重试。",
    .toast_quick_ai_done = "AI 配置完成，DeepSeek 已就绪。",
```

- [ ] **Step 4: Compile-check + commit**

Run: `zig build test` (expect: PASS — any missing language literal shows as "missing struct field <name>"; add it there too)
Run: `zig fmt --check build.zig src` (expect: clean)

```bash
git add src/i18n.zig
git commit -m "feat(ai): i18n strings for quick configure overlay"
```

---

### Task 5: Overlay shell in `overlays.zig` (open/close/input/render)

This task adds all the overlay plumbing as new `pub`/private functions and as sibling branches next to the existing Feishu branches. Nothing references the command yet (that is Task 8), so the build stays green with these functions present-but-unwired. Verified by compile + format (UI behavior is exercised manually at the end).

**Files:**
- Modify: `src/renderer/overlays.zig`

**Interfaces:**
- Consumes: `quick_ai_config` (Task 1), `quick_verify` (Task 2), `OverlayState.quick_ai` (Task 3), i18n fields (Task 4), existing `AppWindow.g_allocator`, `AppWindow.g_force_rebuild`, `g_session_launcher_visible`, `commandPaletteClose()`, `showStatusToast()`, `assistant_profile_store`, `assistantProfiles()`, `Config.setConfigValue`.
- Produces (used by Tasks 6–8): `openQuickAiForm()`, `closeQuickAiForm()`, `quickAiForm()`, `quickAi()`, and the input/render branches.

- [ ] **Step 1: Add imports near the other overlay-module imports (top of file, by line 46 `const feishu_config = ...`)**

```zig
const quick_ai_config = @import("overlays/quick_ai_config.zig");
const quick_verify = @import("../assistant/quick_verify.zig");
```

Also ensure these two are imported somewhere near the top (add if missing — check first):

```zig
const platform_open_url = @import("../platform/open_url.zig");
const window_backend = @import("../platform/window_backend.zig");
```

- [ ] **Step 2: Add accessors next to `feishuForm()` / `feishuConfig()` (around line 123)**

```zig
fn quickAiForm() *overlay_state.QuickAiFormState {
    return &g_overlay_state.quick_ai;
}

fn quickAi() *quick_ai_config.State {
    return &g_overlay_state.quick_ai.config;
}
```

(Use the same `overlay_state` import alias the file already uses for `FeishuFormState`.)

- [ ] **Step 3: Add open/close + URL helper, modeled on `openFeishuConfigForm`/`closeFeishuConfigForm` (around line 3955–3982)**

```zig
/// Quick Configure AI: guided overlay to paste + verify a DeepSeek key.
/// Rides on the session-launcher plumbing like the Feishu form.
pub fn openQuickAiForm() void {
    commandPaletteClose(); // mirror Feishu: close palette FIRST, then set our visible flag
    quickAi().reset();
    g_session_launcher_visible = true;
    quickAiForm().visible = true;
    AppWindow.g_force_rebuild = true;
}

fn closeQuickAiForm() void {
    quickAiForm().visible = false;
    g_session_launcher_visible = false;
    quickAi().reset();
    AppWindow.g_force_rebuild = true;
}

fn openQuickAiUrl(url: []const u8) void {
    if (AppWindow.g_allocator) |alloc| _ = platform_open_url.open(alloc, .{ .url = url });
}
```

> Open `openFeishuConfigForm` (line 3955) and `closeFeishuConfigForm` (line 3979) and confirm the exact launcher-visibility handshake; match it. If Feishu sets/uses a different repaint signal than `AppWindow.g_force_rebuild`, use the same one.

- [ ] **Step 4: Add the char-input branch as a sibling to the Feishu branch at line 2496**

The Feishu branch reads:
```zig
    if (feishuForm().visible) {
        const field = feishuConfig().focusedField() orelse return;
        ...
        feishuConfig().append(field, buf[0..n]);
    }
```
Add immediately before or after it:
```zig
    if (quickAiForm().visible) {
        if (quickAi().focus != quick_ai_config.ROW_KEY) return;
        quickAi().append(buf[0..n]);
        AppWindow.g_force_rebuild = true;
        return;
    }
```
(`buf[0..n]` is the same UTF-8 byte slice the Feishu branch appends — reuse whatever local the surrounding function already has there.)

- [ ] **Step 5: Add the paste branch as a sibling to the Feishu branch at line 2523**

The Feishu branch reads:
```zig
    if (feishuForm().visible) {
        const field = feishuConfig().focusedField() orelse return false;
        feishuConfig().append(field, text);
        return true;
    }
```
Add immediately before/after it:
```zig
    if (quickAiForm().visible) {
        if (quickAi().focus != quick_ai_config.ROW_KEY) return false;
        quickAi().append(text);
        AppWindow.g_force_rebuild = true;
        return true;
    }
```

- [ ] **Step 6: Add the key-handler branch as a sibling to the Feishu branch at line 2587**

The Feishu branch is a `if (feishuForm().visible) { switch (key) { ... } }`. Add a sibling:
```zig
    if (quickAiForm().visible) {
        switch (key) {
            .tab, .arrow_down => quickAi().focusNextRow(),
            .arrow_up => quickAi().focusPrevRow(),
            .enter => switch (quickAi().focus) {
                quick_ai_config.ROW_OPEN_REGISTER => openQuickAiUrl(quick_ai_config.REGISTER_URL),
                quick_ai_config.ROW_OPEN_TUTORIAL => openQuickAiUrl(quick_ai_config.TUTORIAL_URL),
                quick_ai_config.ROW_KEY => quickAi().focus = quick_ai_config.ROW_VERIFY,
                quick_ai_config.ROW_VERIFY => {}, // inert in this task; Task 6 rewires this arm to startQuickAiVerify()
                else => {},
            },
            .backspace => if (quickAi().focus == quick_ai_config.ROW_KEY) quickAi().backspace(),
            .escape => closeQuickAiForm(),
            else => {},
        }
        AppWindow.g_force_rebuild = true;
        return; // match the Feishu branch's exact return/effect convention
    }
```
> Verify is intentionally inert in this task — the `ROW_VERIFY` arm is a no-op so the overlay shell compiles standalone. Task 6 defines `startQuickAiVerify()` and rewires this arm. (Same for the mouse path if you add one.)

- [ ] **Step 7: Add the commit-cleanup line next to the Feishu one at line 2437**

Where the code clears `feishuForm().visible = false;` on overlay-commit transitions, add:
```zig
    quickAiForm().visible = false;
```

- [ ] **Step 8: Add the form title + row count, mirroring Feishu at lines 4690 and 4873**

At the title site (line 4690, where `if (feishuForm().visible) return i18n.s().feishu_form_title;`):
```zig
    if (quickAiForm().visible) return i18n.s().quick_ai_form_title;
```
At the row-count site (line 4873, where `feishuForm().visible` returns `FEISHU_ROW_COUNT`):
```zig
    if (quickAiForm().visible) return quick_ai_config.ROW_COUNT;
```

- [ ] **Step 9: Add the render branch inside `renderSessionLauncher` (mirror the `feishuForm().visible` draw block)**

Open the Feishu draw block inside `renderSessionLauncher` (starts near line 5215; find the `feishuForm().visible` branch) and add a sibling `if (quickAiForm().visible) { ... }` block that draws, top to bottom:

1. Title: `i18n.s().quick_ai_form_title`
2. Intro line: `i18n.s().quick_ai_intro`
3. Row `ROW_OPEN_REGISTER`: `i18n.s().quick_ai_register_row` (highlight when `quickAi().focus == ROW_OPEN_REGISTER`)
4. Row `ROW_OPEN_TUTORIAL`: `i18n.s().quick_ai_tutorial_row` (highlight when focused)
5. Row `ROW_KEY`: label "API Key:" + the key **masked** as `•` repeated `quickAi().key().len` times (NEVER draw the raw key); highlight when `quickAi().focus == ROW_KEY`
6. Row `ROW_VERIFY`: `i18n.s().quick_ai_verify_row` (highlight when focused)
7. Status line, chosen from `quickAi().status`:
   - `.idle` → `quick_ai_status_idle`
   - `.verifying` → `quick_ai_status_verifying`
   - `.empty` → `quick_ai_status_empty`
   - `.invalid` → `quick_ai_status_invalid`
   - `.network` → `quick_ai_status_network`
   - `.ok` → `toast_quick_ai_done` (rarely seen — overlay closes on success)

Use the exact text-drawing primitives, row geometry, and focus-highlight color the Feishu block uses; only the row contents differ. Implement the status selection as a small helper:
```zig
fn quickAiStatusText() []const u8 {
    return switch (quickAi().status) {
        .idle => i18n.s().quick_ai_status_idle,
        .verifying => i18n.s().quick_ai_status_verifying,
        .empty => i18n.s().quick_ai_status_empty,
        .invalid => i18n.s().quick_ai_status_invalid,
        .network => i18n.s().quick_ai_status_network,
        .ok => i18n.s().toast_quick_ai_done,
    };
}
```

- [ ] **Step 10: Build + format + commit**

Run: `zig build macos-app -Dtarget=aarch64-macos` (expect: builds clean)
Run: `zig build test-full -Dtarget=aarch64-macos` (expect: PASS)
Run: `zig fmt --check build.zig src` (expect: clean)

```bash
git add src/renderer/overlays.zig
git commit -m "feat(ai): quick configure overlay shell (open/close/input/render)"
```

---

### Task 6: Verify + apply wiring in `overlays.zig`

**Files:**
- Modify: `src/renderer/overlays.zig`

**Interfaces:**
- Consumes: `quick_verify.start`/`take` (Task 2), `quick_ai_config.upsertProfiles` (Task 1), `assistant_profile_store.loadProfiles`/`saveProfiles`, `assistantProfiles()`, `Config.setConfigValue`, `window_backend.postWakeup`, `showStatusToast`.
- Produces (used by Task 7): `pub fn tickQuickAiVerify()`. Also `startQuickAiVerify()` referenced by Task 5 Step 6.

- [ ] **Step 1: Add `startQuickAiVerify` (main thread: kick off the worker)**

```zig
fn startQuickAiVerify() void {
    const k = quickAi().key();
    if (k.len == 0) {
        quickAi().status = .empty;
        AppWindow.g_force_rebuild = true;
        return;
    }
    quickAi().status = .verifying;
    AppWindow.g_force_rebuild = true;
    // Worker wakes the UI when done; window_backend.postWakeup is safe from background threads.
    _ = quick_verify.start(quick_ai_config.BASE_URL, k, window_backend.postWakeup);
}
```
> Confirm the exact wake symbol in `src/platform/window_backend.zig` (it is the `postWakeup`-style `pub fn ... () void` the termio threads call). If the name differs, pass that function here.

- [ ] **Step 2: Add `applyQuickAiConfig` (main thread: persist the two profiles + config keys)**

```zig
fn applyQuickAiConfig() void {
    const allocator = AppWindow.g_allocator orelse return;
    const profiles = assistantProfiles().profiles[0..];
    var count = assistant_profile_store.loadProfiles(allocator, profiles);
    count = quick_ai_config.upsertProfiles(profiles, count, quickAi().key());
    assistantProfiles().profile_count = count;
    _ = assistant_profile_store.saveProfiles(allocator, profiles[0..count]);
    Config.setConfigValue(allocator, "ai-default-profile", quick_ai_config.MAIN_PROFILE_NAME) catch {};
    Config.setConfigValue(allocator, "ai-subagent-profile", quick_ai_config.SUB_PROFILE_NAME) catch {};
    showStatusToast(i18n.s().toast_quick_ai_done);
    closeQuickAiForm();
}
```
> Confirm `assistant_profile_store` is the import alias used at overlays.zig:4623/4627 and `assistantProfiles()` is the accessor at line 120. Use those exact names.

- [ ] **Step 3: Add `tickQuickAiVerify` (main thread: drain the channel each frame)**

```zig
/// Called every frame from the main loop. Drains a finished verify result and,
/// if the overlay is still open, applies it (success) or shows the error.
pub fn tickQuickAiVerify() void {
    const outcome = quick_verify.take() orelse return; // always drain to clear the channel
    if (!quickAiForm().visible) return; // overlay was closed mid-verify — drop stale result
    switch (outcome) {
        .ok => applyQuickAiConfig(),
        .invalid_key => quickAi().status = .invalid,
        .network_error => quickAi().status = .network,
    }
    AppWindow.g_force_rebuild = true;
}
```

- [ ] **Step 4: Rewire the Verify row to call `startQuickAiVerify`**

In the key-handler branch added in Task 5 Step 6, change the inert `ROW_VERIFY` arm:

```zig
                quick_ai_config.ROW_VERIFY => {}, // inert in this task; Task 6 rewires this arm to startQuickAiVerify()
```
to:
```zig
                quick_ai_config.ROW_VERIFY => startQuickAiVerify(),
```

- [ ] **Step 5: Build + format + commit**

Run: `zig build macos-app -Dtarget=aarch64-macos` (expect: builds clean — `startQuickAiVerify` referenced from Task 5 Step 6 now resolves)
Run: `zig build test-full -Dtarget=aarch64-macos` (expect: PASS)
Run: `zig fmt --check build.zig src` (expect: clean)

```bash
git add src/renderer/overlays.zig
git commit -m "feat(ai): quick configure verify + apply (upsert profiles, set config)"
```

---

### Task 7: Main-loop tick in `AppWindow.zig`

**Files:**
- Modify: `src/AppWindow.zig` (the `while (running)` body in `runMainLoop`, next to line 6670 `overlays.tickSessionLauncher();`)

**Interfaces:**
- Consumes: `overlays.tickQuickAiVerify()` (Task 6).

- [ ] **Step 1: Add the tick call right after `overlays.tickSessionLauncher();` (line 6670)**

```zig
        overlays.tickQuickAiVerify();
```

- [ ] **Step 2: Build + commit**

Run: `zig build macos-app -Dtarget=aarch64-macos` (expect: builds clean)
Run: `zig fmt --check build.zig src` (expect: clean)

```bash
git add src/AppWindow.zig
git commit -m "feat(ai): drain quick-configure verify result each frame"
```

---

### Task 8: Wire the command (the entry point) — center_state + i18n arms + dispatch

This is the "power-on" task. Adding `quick_configure_ai` to the exhaustive `CommandAction` switches in `commandTitle`/`commandDetail` forces the i18n arms; the dispatch arm calls `openQuickAiForm()` (Task 5). All four edit sites are exactly where `configure_feishu` already appears.

**Files:**
- Modify: `src/command/center_state.zig` (enum + `command_entries` + test)
- Modify: `src/i18n.zig` (`commandTitle` + `commandDetail` switches)
- Modify: `src/renderer/overlays.zig` (command dispatch switch at line 687)

**Interfaces:**
- Consumes: `openQuickAiForm()` (Task 5).
- Produces: the user-visible command.

- [ ] **Step 1: Add the enum variant to `CommandAction` (center_state.zig, next to `configure_feishu` at line 38)**

```zig
    quick_configure_ai,
```

- [ ] **Step 2: Add the command entry to `command_entries` (next to the Feishu entry at line 93)**

```zig
    .{ .title = "Settings: Quick Configure AI", .detail = "Paste one DeepSeek API key to set up the main + subagent models", .shortcut = "", .action = .quick_configure_ai },
```

- [ ] **Step 3: Add the entry test (next to "command center includes Feishu direct actions" at line ~417)**

```zig
test "command center includes quick configure AI" {
    try expectCommandEntry("Settings: Quick Configure AI", .quick_configure_ai);
}
```

- [ ] **Step 4: Add the i18n title + detail arms (i18n.zig, next to the `.configure_feishu` arms)**

In the `commandTitle` switch (line ~840, the `.configure_feishu => "飞书：配置",` arm):
```zig
        .quick_configure_ai => "设置：快速配置 AI",
```
In the `commandDetail` switch (line ~893, the `.configure_feishu => ...` arm):
```zig
        .quick_configure_ai => "粘贴一个 DeepSeek API key，自动配好主模型和 subagent",
```

- [ ] **Step 5: Add the dispatch arm (overlays.zig, next to `.configure_feishu => openFeishuConfigForm()` at line 687)**

```zig
        .quick_configure_ai => openQuickAiForm(),
```

- [ ] **Step 6: Build everything + run tests**

Run: `zig build test` (expect: PASS — includes the new center_state entry test)
Run: `zig build test-full -Dtarget=aarch64-macos` (expect: PASS)
Run: `zig build macos-app -Dtarget=aarch64-macos` (expect: builds clean)
Run: `zig fmt --check build.zig src` (expect: clean)

> If the build reports any other exhaustive `switch (action)` over `CommandAction` missing `.quick_configure_ai`, add an arm there mirroring that switch's `.configure_feishu` arm. (Per a repo-wide grep at planning time, the only such sites are the two i18n switches + this dispatch — but trust the compiler.)

- [ ] **Step 7: Commit**

```bash
git add src/command/center_state.zig src/i18n.zig src/renderer/overlays.zig
git commit -m "feat(ai): add Settings: Quick Configure AI command"
```

---

### Task 9: Manual end-to-end verification

**Files:** none (real-app check from the spec's verification baseline).

- [ ] **Step 1: Launch the freshly built app**

Run: `zig build macos-app -Dtarget=aarch64-macos` then open the built `.app` (per the repo's usual run flow / `/run`).

- [ ] **Step 2: Happy path**

Open the command palette → run **Settings: Quick Configure AI**. Confirm:
- The two link rows open `platform.deepseek.com` / the wiki URL in a browser on Enter.
- Pasting into the key row shows masked `•`.
- With a **valid** DeepSeek key, pressing Verify shows "Verifying…" then the "AI configured" toast and the overlay closes.
- `~/.config/wispterm/ai_profiles` now contains `DeepSeek` (`deepseek-v4-pro`) and `DeepSeek Flash` (`deepseek-v4-flash`) lines with the pasted key.
- The config file now has `ai-default-profile = DeepSeek` and `ai-subagent-profile = DeepSeek Flash`.
- A new Copilot/Agent defaults to the DeepSeek v4-pro profile.

- [ ] **Step 3: Failure path**

Reopen the overlay, paste an **invalid** key, press Verify → status shows "Invalid API key", the overlay stays open, and NO profile/config is written. Press Verify with an empty field → "Paste an API key first."

- [ ] **Step 4: Final commit (if any cleanup was needed)**

```bash
git status   # expect clean if no changes were needed
```

---

## Self-Review (completed during planning)

**Spec coverage:** command (Task 8) · guided overlay with register+tutorial links (Task 5) · single masked key field (Tasks 1,5) · async GET /models verify off the UI thread (Task 2) · main-thread drain/apply (Tasks 6,7) · upsert two profiles + set both config keys (Tasks 1,6) · i18n EN+ZH (Task 4,8) · security: no-log / mask / no-prefill / no-key-in-status (Tasks 1,5,6) · error handling: empty/invalid/network, no partial apply (Tasks 6) · tests fast + full + manual (Tasks 1,2,9) · verification baseline commands (Global Constraints, Task 9). No gaps found.

**Placeholder scan:** the only "placeholder" is the deliberate, spec-approved `TUTORIAL_URL` constant (named, one-line change). No TBD/TODO/"handle errors" left.

**Type consistency:** `VerifyStatus{idle,verifying,ok,empty,invalid,network}` used identically in Tasks 1/3/5/6; `quick_verify.Outcome{ok,invalid_key,network_error}` mapped to `VerifyStatus` only in `tickQuickAiVerify` (Task 6); `upsertProfiles(profiles, count, api_key) usize` signature identical in Tasks 1 and 6; accessor names `quickAiForm()`/`quickAi()` consistent Tasks 3/5/6.
