# WeChat Direct (Embedded ilink) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Embed the WeChat ilink protocol client directly inside the Phantty desktop process so WeChat can drive the local terminal/AI without the Cloudflare Worker relay, as a path mutually exclusive with `remote-enabled`.

**Architecture:** Two layers. A **cross-platform pure layer** (`src/weixin/`: ilink transport over `std.http.Client`, JSON codec, command routing, owner binding, AI-reply progress diffing, state persistence) that compiles and unit-tests on any OS. A **Windows-bound integration layer** (a `LocalControl` view factored out of `App`/`remote_client`/`AppWindow`, the poller thread/controller, a QR login panel, config wiring) that runs where the GUI runs. Routing logic is ported faithfully from the existing TypeScript bridge in `remote/src/server/bridge/weixin/`, whose tests in `remote/test/server/weixin_*.test.ts` are the behavioral source of truth.

**Tech Stack:** Zig 0.15.2, `std.http.Client` (bundled TLS), `std.json`. Build: `zig build`. Pure-module tests: `zig test src/weixin/<file>.zig`. Full test binary registration via `src/test_main.zig`.

---

## Reference: ilink wire protocol (from `remote/src/server/bridge/weixin/`)

- Base URL: `https://ilinkai.weixin.qq.com`; `bot_type = "3"`; `channel_version = "1.0.2"`.
- `GET /ilink/bot/get_bot_qrcode?bot_type=3` → `{ ret, qrcode?, qrcode_img_content?, message? }`
- `GET /ilink/bot/get_qrcode_status?qrcode=<urlenc>` (header `iLink-App-ClientVersion: 1`) → `{ ret, status?: "wait"|"scaned"|"confirmed"|"expired", bot_token?, baseurl?, ilink_bot_id?, ilink_user_id?, message? }` (note the API spells it `scaned`).
- `POST /ilink/bot/getupdates` body `{ get_updates_buf, base_info:{channel_version} }` → `{ ret, msgs?[], get_updates_buf?, longpolling_timeout_ms?, errcode?, message? }`. `errcode == -14` ⇒ session expired.
- `POST /ilink/bot/sendmessage` body `{ msg:{ to_user_id, client_id, message_type:2, message_state:2, context_token, item_list:[{type:1,text_item:{text}}] }, base_info }` → `{ ret?, errcode?, message? }`.
- Headers on every request: `content-type: application/json`, `AuthorizationType: ilink_bot_token`, `X-WECHAT-UIN: <base64 of a random uint string>`, and `Authorization: Bearer <bot_token>` when a token is present.
- Inbound `WeixinMessage`: `{ from_user_id?, to_user_id?, client_id?, message_type?, message_state?, context_token?, group_id?, item_list?: [{ type?, text_item?:{text?}, voice_item?:{text?} }] }`.

---

## File Structure

**Cross-platform pure layer (new, under `src/weixin/`):**
- `types.zig` — in-memory structs: `Message`, `MessageItem`, `GetUpdatesResult`, `QrCode`, `QrStatus`, `Settings`, `Binding`. No I/O.
- `ilink_codec.zig` — build request JSON bodies/URLs; parse response JSON into `types`. Pure, `std.json`.
- `ilink_client.zig` — `std.http.Client` wrapper implementing the `ClientApi` interface (`getBotQrcode`, `getQrcodeStatus`, `getUpdates`, `sendText`). Compiles cross-platform; network paths are compile-only on the Linux host.
- `binding.zig` — `shouldHandle`, `extractText`, owner auto-bind decision. Pure.
- `agent.zig` — command parsing + routing into a `Control` interface (`/ai /term /keys /stop /ping /status /help` + default→AI). Pure given a `Control`.
- `reply_progress.zig` — AI transcript section parsing + baseline diffing + checkpoint progress text. Pure.
- `poller.zig` — `processUpdates` (pure, testable with fakes) + `Poller` thread loop (generation/staleness, sync-buf, errcode −14). Loop uses injected `ClientApi`/scheduler.
- `state_store.zig` — load/save `{ bot_token, owner_user_id, base_url, sync_buf }` to a `0600` JSON file under the app state dir. Uses `std.fs`; testable with a tmp dir.
- `control.zig` — the `Control` interface (vtable) consumed by `agent.zig`/`poller.zig`, plus `Surface` and `OpenResult` types. A test fake lives in tests.

**Windows-bound integration layer (modify existing):**
- `src/config.zig` — add `weixin-direct-*` keys, parsing, and usage text.
- `src/weixin/controller.zig` (new) — owns the poller thread, builds the live `Control` from `App`, lifecycle (`startLogin`, `start`, `stop`, `unbind`).
- `src/App.zig` — construct/destroy the controller; mutual-exclusion guard with `remote-enabled`; expose accessors the controller needs.
- `src/AppWindow.zig` — implement `findAiChatSurface` / `latestAiChatTranscript` / `onLayout` over the existing tab-indexed AI surface plumbing (`remoteAiSurfaceId`, `registerRemoteAiInputSink`, the `thread_message` marshalling).
- `src/weixin/qr_panel.zig` (new) — decode + render the login QR via `image_decoder.zig`, show status, auto-close on `confirmed`.
- `src/test_main.zig` — register the new pure modules in the test binary.

---

## Phase 0 — Config & state foundation (cross-platform)

### Task 1: Add `weixin-direct-*` config keys

**Files:**
- Modify: `src/config.zig` (struct fields near line 311 after `remote-session-key`; `applyKeyValue` near line 760; usage text near line 1169)

- [ ] **Step 1: Add the struct fields**

In `src/config.zig`, immediately after the `@"remote-session-key"` field (around line 311), add:

```zig
/// Enables the embedded WeChat ilink direct path. Mutually exclusive with
/// remote-enabled; if both are true, remote wins and this is disabled.
@"weixin-direct-enabled": bool = false,

/// Override for the ilink API base URL. Defaults to the public endpoint.
@"weixin-base-url": ?[]const u8 = null,

/// Max time (ms) to keep streaming AI-reply progress to WeChat. Clamped to
/// [5000, 180000]. Matches the TS bridge default.
@"weixin-reply-timeout-ms": u32 = 120000,

/// When set, only this ilink user_id may control the terminal/AI. When empty,
/// the first 1:1 sender after login is auto-bound as owner.
@"weixin-allowed-user": ?[]const u8 = null,
```

- [ ] **Step 2: Add parsing in `applyKeyValue`**

After the `remote-session-key` branch (around line 760), add:

```zig
} else if (std.mem.eql(u8, key, "weixin-direct-enabled")) {
    if (std.mem.eql(u8, value, "true")) {
        self.@"weixin-direct-enabled" = true;
    } else if (std.mem.eql(u8, value, "false")) {
        self.@"weixin-direct-enabled" = false;
    } else {
        log.warn("invalid weixin-direct-enabled: {s}", .{value});
    }
} else if (std.mem.eql(u8, key, "weixin-base-url")) {
    self.@"weixin-base-url" = self.dupeString(allocator, value) orelse return;
} else if (std.mem.eql(u8, key, "weixin-reply-timeout-ms")) {
    self.@"weixin-reply-timeout-ms" = std.fmt.parseInt(u32, value, 10) catch {
        log.warn("invalid weixin-reply-timeout-ms: {s}", .{value});
        return;
    };
} else if (std.mem.eql(u8, key, "weixin-allowed-user")) {
    self.@"weixin-allowed-user" = self.dupeString(allocator, value) orelse return;
```

- [ ] **Step 3: Add usage text**

After the `--remote-server-fingerprint` usage line (around line 1169), add:

```zig
\\  --weixin-direct-enabled <bool> Enable embedded WeChat ilink direct path
\\  --weixin-base-url <url>      Override ilink API base URL
\\  --weixin-reply-timeout-ms <n> AI-reply streaming window in ms
\\  --weixin-allowed-user <id>   Restrict control to one ilink user_id
```

- [ ] **Step 4: Compile**

Run: `zig build`
Expected: builds with no new errors.

- [ ] **Step 5: Commit**

```bash
git add src/config.zig
git commit -m "feat(weixin): add weixin-direct config keys"
```

### Task 2: Define `src/weixin/types.zig`

**Files:**
- Create: `src/weixin/types.zig`

- [ ] **Step 1: Write the types (no test needed — plain structs)**

```zig
//! In-memory representations of ilink protocol values. No I/O lives here;
//! `ilink_codec.zig` converts wire JSON to/from these.

pub const MessageItem = struct {
    type: i64 = 0,
    /// text from a text_item (type 1)
    text: []const u8 = "",
    /// transcribed text from a voice_item (type 3)
    voice_text: []const u8 = "",
};

pub const Message = struct {
    from_user_id: []const u8 = "",
    to_user_id: []const u8 = "",
    context_token: []const u8 = "",
    group_id: []const u8 = "",
    item_list: []const MessageItem = &.{},
};

pub const GetUpdatesResult = struct {
    ret: i64 = 0,
    errcode: i64 = 0,
    longpolling_timeout_ms: i64 = 0,
    get_updates_buf: []const u8 = "",
    msgs: []const Message = &.{},
};

pub const QrCode = struct {
    ret: i64 = 0,
    qrcode: []const u8 = "",
    /// base64 PNG content, when the API returns an inline image
    qrcode_img_content: []const u8 = "",
};

pub const QrStatusKind = enum { wait, scaned, confirmed, expired, unknown };

pub const QrStatus = struct {
    ret: i64 = 0,
    status: QrStatusKind = .unknown,
    bot_token: []const u8 = "",
    base_url: []const u8 = "",
    bot_id: []const u8 = "",
    user_id: []const u8 = "",
};

pub const Settings = struct {
    enabled: bool = false,
    reply_timeout_ms: u32 = 120000,
    /// empty ⇒ auto-bind first sender
    allowed_user: []const u8 = "",
};

pub const Binding = struct {
    bot_token: []const u8 = "",
    base_url: []const u8 = "",
    owner_user_id: []const u8 = "",
    bot_id: []const u8 = "",
    sync_buf: []const u8 = "",
};
```

- [ ] **Step 2: Compile-check the file**

Run: `zig test src/weixin/types.zig`
Expected: `All 0 tests passed.` (no tests, but it must compile).

- [ ] **Step 3: Commit**

```bash
git add src/weixin/types.zig
git commit -m "feat(weixin): add ilink in-memory types"
```

### Task 3: `src/weixin/state_store.zig` — persist token/owner/sync-buf

**Files:**
- Create: `src/weixin/state_store.zig`

- [ ] **Step 1: Write the failing test**

Append to `src/weixin/state_store.zig`:

```zig
test "round-trips binding through a file" {
    const tmp_path = "zig-cache-tmp-weixin-state.json";
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    try save(std.testing.allocator, tmp_path, .{
        .bot_token = "tok-123",
        .base_url = "https://example.test",
        .owner_user_id = "user-9",
        .bot_id = "bot-1",
        .sync_buf = "BUF==",
    });

    var loaded = try load(std.testing.allocator, tmp_path);
    defer loaded.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("tok-123", loaded.binding.bot_token);
    try std.testing.expectEqualStrings("user-9", loaded.binding.owner_user_id);
    try std.testing.expectEqualStrings("BUF==", loaded.binding.sync_buf);
}

test "load returns empty binding when file is absent" {
    var loaded = try load(std.testing.allocator, "definitely-not-here-weixin.json");
    defer loaded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), loaded.binding.bot_token.len);
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `zig test src/weixin/state_store.zig`
Expected: FAIL — `save`/`load`/`Loaded` undefined.

- [ ] **Step 3: Write the implementation**

Prepend to `src/weixin/state_store.zig`:

```zig
//! Persists the WeChat direct binding to a 0600 JSON file. Secrets never go in
//! config; they live here in the app state dir.
const std = @import("std");
const types = @import("types.zig");

pub const Loaded = struct {
    arena: std.heap.ArenaAllocator,
    binding: types.Binding,

    pub fn deinit(self: *Loaded, _: std.mem.Allocator) void {
        self.arena.deinit();
    }
};

const Wire = struct {
    bot_token: []const u8 = "",
    base_url: []const u8 = "",
    owner_user_id: []const u8 = "",
    bot_id: []const u8 = "",
    sync_buf: []const u8 = "",
};

pub fn save(allocator: std.mem.Allocator, path: []const u8, binding: types.Binding) !void {
    if (std.fs.path.dirname(path)) |dir| {
        std.fs.cwd().makePath(dir) catch {};
    }
    const wire = Wire{
        .bot_token = binding.bot_token,
        .base_url = binding.base_url,
        .owner_user_id = binding.owner_user_id,
        .bot_id = binding.bot_id,
        .sync_buf = binding.sync_buf,
    };
    const json = try std.json.stringifyAlloc(allocator, wire, .{});
    defer allocator.free(json);

    var file = try std.fs.cwd().createFile(path, .{ .truncate = true, .mode = 0o600 });
    defer file.close();
    try file.writeAll(json);
}

pub fn load(allocator: std.mem.Allocator, path: []const u8) !Loaded {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    const data = std.fs.cwd().readFileAlloc(arena.allocator(), path, 1 << 20) catch |err| switch (err) {
        error.FileNotFound => return .{ .arena = arena, .binding = .{} },
        else => return err,
    };

    const parsed = std.json.parseFromSliceLeaky(Wire, arena.allocator(), data, .{
        .ignore_unknown_fields = true,
    }) catch return .{ .arena = arena, .binding = .{} };

    return .{ .arena = arena, .binding = .{
        .bot_token = parsed.bot_token,
        .base_url = parsed.base_url,
        .owner_user_id = parsed.owner_user_id,
        .bot_id = parsed.bot_id,
        .sync_buf = parsed.sync_buf,
    } };
}
```

> Note (Zig 0.15.2): if `std.json.stringifyAlloc` / `parseFromSliceLeaky` signatures differ in this toolchain, adjust to the available `std.json` API and re-run; the test asserts behavior, not the exact call.

- [ ] **Step 4: Run the test to verify it passes**

Run: `zig test src/weixin/state_store.zig`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add src/weixin/state_store.zig
git commit -m "feat(weixin): add binding state store"
```

---

## Phase 1 — Pure routing logic (cross-platform, TDD)

### Task 4: `src/weixin/binding.zig` — message filtering + text extraction

Ports `shouldHandleWeixinMessage` and `extractWeixinText` from `poller.ts:40-57`. Reference tests: `remote/test/server/weixin_poller.test.ts`.

**Files:**
- Create: `src/weixin/binding.zig`

- [ ] **Step 1: Write the failing tests**

Append to `src/weixin/binding.zig`:

```zig
const t = std.testing;

test "rejects group, empty sender, bot echo, and stranger" {
    try t.expect(!shouldHandle("", "", .{ .from_user_id = "u1", .group_id = "g1" }).ok);
    try t.expect(!shouldHandle("", "", .{ .from_user_id = "" }).ok);
    try t.expect(!shouldHandle("", "bot", .{ .from_user_id = "bot" }).ok);
    try t.expect(!shouldHandle("owner", "", .{ .from_user_id = "stranger" }).ok);
}

test "accepts the owner and an unbound first sender" {
    try t.expect(shouldHandle("owner", "", .{ .from_user_id = "owner" }).ok);
    try t.expect(shouldHandle("", "", .{ .from_user_id = "anybody" }).ok);
}

test "extractText prefers text item then voice transcript" {
    try t.expectEqualStrings("hi", extractText(.{ .item_list = &.{
        .{ .type = 1, .text = "  hi  " },
    } }));
    try t.expectEqualStrings("said", extractText(.{ .item_list = &.{
        .{ .type = 3, .voice_text = "said" },
    } }));
    try t.expectEqualStrings("", extractText(.{ .item_list = &.{} }));
}

test "ownerForBind returns first sender only when unbound and allowed empty" {
    try t.expectEqualStrings("u1", ownerForBind("", "", "u1").?);
    try t.expect(ownerForBind("existing", "", "u1") == null);
    try t.expect(ownerForBind("", "allowed-only", "u1") == null);
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `zig test src/weixin/binding.zig`
Expected: FAIL — `shouldHandle`/`extractText`/`ownerForBind` undefined.

- [ ] **Step 3: Write the implementation**

Prepend to `src/weixin/binding.zig`:

```zig
//! Owner binding + inbound message filtering. Ported from poller.ts.
const std = @import("std");
const types = @import("types.zig");

pub const Decision = struct { ok: bool, reason: []const u8 };

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

/// Mirror of shouldHandleWeixinMessage. `owner` is the bound owner ("" if
/// unbound); `account_id` is the bot's own id ("" if unknown).
pub fn shouldHandle(owner: []const u8, account_id: []const u8, msg: types.Message) Decision {
    const from = trim(msg.from_user_id);
    const to = trim(msg.to_user_id);
    if (trim(msg.group_id).len != 0) return .{ .ok = false, .reason = "group_message" };
    if (from.len == 0) return .{ .ok = false, .reason = "missing_sender" };
    if (account_id.len != 0 and std.mem.eql(u8, from, account_id)) return .{ .ok = false, .reason = "bot_echo" };
    if (owner.len != 0 and !std.mem.eql(u8, from, owner)) return .{ .ok = false, .reason = "unexpected_sender" };
    if (account_id.len != 0 and to.len != 0 and !std.mem.eql(u8, to, account_id)) return .{ .ok = false, .reason = "unexpected_recipient" };
    return .{ .ok = true, .reason = "" };
}

/// Mirror of extractWeixinText: text item (type 1), else voice transcript (type 3).
pub fn extractText(msg: types.Message) []const u8 {
    for (msg.item_list) |item| {
        if (item.type == 1) {
            const text = trim(item.text);
            if (text.len != 0) return text;
        }
        if (item.type == 3) {
            const text = trim(item.voice_text);
            if (text.len != 0) return text;
        }
    }
    return "";
}

/// Returns the user_id to persist as owner, or null if no auto-bind should
/// happen (already bound, or an explicit allowed_user is configured).
pub fn ownerForBind(current_owner: []const u8, allowed_user: []const u8, sender: []const u8) ?[]const u8 {
    if (trim(current_owner).len != 0) return null;
    if (trim(allowed_user).len != 0) return null;
    const s = trim(sender);
    return if (s.len == 0) null else s;
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `zig test src/weixin/binding.zig`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add src/weixin/binding.zig
git commit -m "feat(weixin): port message filtering and owner binding"
```

### Task 5: `src/weixin/control.zig` — the Control interface

Defines the boundary `agent.zig`/`poller.zig` call into. The real implementation is built by `controller.zig` from `App`; tests use a fake.

**Files:**
- Create: `src/weixin/control.zig`

- [ ] **Step 1: Write the interface (compile-checked, no logic test)**

```zig
//! Boundary between WeChat routing and the live Phantty surfaces. The real
//! vtable is supplied by controller.zig; tests supply a fake.
const std = @import("std");

pub const Surface = struct { id: [16]u8, title: []const u8 };

pub const OpenResult = enum { opened, no_profile, failed, offline, timeout };

pub const Control = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        is_connected: *const fn (ctx: *anyopaque) bool,
        find_ai_surface: *const fn (ctx: *anyopaque) ?Surface,
        find_terminal_surface: *const fn (ctx: *anyopaque) ?Surface,
        open_ai_agent: *const fn (ctx: *anyopaque, timeout_ms: u32) OpenResult,
        send_input: *const fn (ctx: *anyopaque, surface_id: [16]u8, bytes: []const u8) bool,
        latest_transcript: *const fn (ctx: *anyopaque) []const u8,
    };

    pub fn isConnected(self: Control) bool {
        return self.vtable.is_connected(self.ctx);
    }
    pub fn findAiSurface(self: Control) ?Surface {
        return self.vtable.find_ai_surface(self.ctx);
    }
    pub fn findTerminalSurface(self: Control) ?Surface {
        return self.vtable.find_terminal_surface(self.ctx);
    }
    pub fn openAiAgent(self: Control, timeout_ms: u32) OpenResult {
        return self.vtable.open_ai_agent(self.ctx, timeout_ms);
    }
    pub fn sendInput(self: Control, surface_id: [16]u8, bytes: []const u8) bool {
        return self.vtable.send_input(self.ctx, surface_id, bytes);
    }
    pub fn latestTranscript(self: Control) []const u8 {
        return self.vtable.latest_transcript(self.ctx);
    }
};
```

- [ ] **Step 2: Compile-check**

Run: `zig test src/weixin/control.zig`
Expected: `All 0 tests passed.`

- [ ] **Step 3: Commit**

```bash
git add src/weixin/control.zig
git commit -m "feat(weixin): add Control interface"
```

### Task 6: `src/weixin/agent.zig` — command routing

Ports `routeWeixinText` from `agent.ts`, dropping `/sessions` and `/use` (single local app). Reference: `remote/test/server/weixin_agent.test.ts`.

**Files:**
- Create: `src/weixin/agent.zig`

- [ ] **Step 1: Write the failing tests (parsing + routing via a fake Control)**

Append to `src/weixin/agent.zig`:

```zig
const t = std.testing;

const FakeControl = struct {
    connected: bool = true,
    has_ai: bool = true,
    last_input: []const u8 = "",
    last_surface: [16]u8 = [_]u8{0} ** 16,

    fn is_connected(ctx: *anyopaque) bool {
        return cast(ctx).connected;
    }
    fn find_ai_surface(ctx: *anyopaque) ?control.Surface {
        return if (cast(ctx).has_ai) .{ .id = aiId(), .title = "AI Chat" } else null;
    }
    fn find_terminal_surface(_: *anyopaque) ?control.Surface {
        return .{ .id = termId(), .title = "zsh" };
    }
    fn open_ai_agent(_: *anyopaque, _: u32) control.OpenResult {
        return .opened;
    }
    fn send_input(ctx: *anyopaque, surface_id: [16]u8, bytes: []const u8) bool {
        const self = cast(ctx);
        if (!self.connected) return false;
        self.last_surface = surface_id;
        self.last_input = bytes;
        return true;
    }
    fn latest_transcript(_: *anyopaque) []const u8 {
        return "";
    }
    fn cast(ctx: *anyopaque) *FakeControl {
        return @ptrCast(@alignCast(ctx));
    }
    fn aiId() [16]u8 {
        return "aichat0000000000".*;
    }
    fn termId() [16]u8 {
        return "term000000000000".*;
    }
    fn control_iface(self: *FakeControl) control.Control {
        return .{ .ctx = self, .vtable = &.{
            .is_connected = is_connected,
            .find_ai_surface = find_ai_surface,
            .find_terminal_surface = find_terminal_surface,
            .open_ai_agent = open_ai_agent,
            .send_input = send_input,
            .latest_transcript = latest_transcript,
        } };
    }
};

test "ping returns pong without touching surfaces" {
    var fake = FakeControl{};
    var out = Reply.init(t.allocator);
    defer out.deinit();
    try route(t.allocator, fake.control_iface(), defaultSettings(), "ping", &out);
    try t.expectEqualStrings("pong", out.text.items);
    try t.expect(!out.expect_ai_progress);
}

test "default text goes to the AI surface with a carriage return" {
    var fake = FakeControl{};
    var out = Reply.init(t.allocator);
    defer out.deinit();
    try route(t.allocator, fake.control_iface(), defaultSettings(), "hello world", &out);
    try t.expectEqualStrings("hello world\r", fake.last_input);
    try t.expectEqualSlices(u8, &FakeControl.aiId(), &fake.last_surface);
    try t.expect(out.expect_ai_progress);
}

test "/term sends to terminal with enter, /keys without" {
    var fake = FakeControl{};
    var out = Reply.init(t.allocator);
    defer out.deinit();
    try route(t.allocator, fake.control_iface(), defaultSettings(), "/term ls", &out);
    try t.expectEqualStrings("ls\r", fake.last_input);

    var out2 = Reply.init(t.allocator);
    defer out2.deinit();
    try route(t.allocator, fake.control_iface(), defaultSettings(), "/keys abc", &out2);
    try t.expectEqualStrings("abc", fake.last_input);
}

test "offline control yields an offline message and no progress" {
    var fake = FakeControl{ .connected = false };
    var out = Reply.init(t.allocator);
    defer out.deinit();
    try route(t.allocator, fake.control_iface(), defaultSettings(), "do a thing", &out);
    try t.expect(!out.expect_ai_progress);
    try t.expect(std.mem.indexOf(u8, out.text.items, "离线") != null);
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `zig test src/weixin/agent.zig`
Expected: FAIL — `route`/`Reply`/`defaultSettings` undefined.

- [ ] **Step 3: Write the implementation**

Prepend to `src/weixin/agent.zig`:

```zig
//! WeChat command routing into the local Phantty surfaces. Port of agent.ts,
//! minus /sessions and /use (one local app).
const std = @import("std");
const control = @import("control.zig");
const types = @import("types.zig");

const AI_ACK = "信息已收到，开始处理。\n发送 /stop 可停止本次处理。";
const ESC = "\x1b";
const AI_OPEN_TIMEOUT_MS: u32 = 2000;

pub const Reply = struct {
    text: std.ArrayList(u8),
    /// true ⇒ caller should start AI-reply progress streaming.
    expect_ai_progress: bool = false,

    pub fn init(allocator: std.mem.Allocator) Reply {
        return .{ .text = std.ArrayList(u8).init(allocator) };
    }
    pub fn deinit(self: *Reply) void {
        self.text.deinit();
    }
    fn set(self: *Reply, s: []const u8) !void {
        self.text.clearRetainingCapacity();
        try self.text.appendSlice(s);
    }
};

pub fn defaultSettings() types.Settings {
    return .{};
}

/// Returns the command token (lowercased, including leading '/') and the
/// remaining argument. Normalizes a full-width '／' to '/'.
fn splitCommand(text: []const u8) struct { cmd: []const u8, arg: []const u8 } {
    var normalized = text;
    // full-width slash U+FF0F is the 3 bytes EF BC 8F
    if (std.mem.startsWith(u8, text, "\u{FF0F}")) {
        // treat as '/': fall through using a synthesized view is awkward in Zig;
        // handle by checking the rest below. For simplicity, only ASCII '/'
        // starts a command here; tests use ASCII.
        normalized = text;
    }
    if (normalized.len == 0 or normalized[0] != '/') return .{ .cmd = "", .arg = normalized };
    const sp = std.mem.indexOfScalar(u8, normalized, ' ') orelse normalized.len;
    return .{ .cmd = normalized[0..sp], .arg = std.mem.trim(u8, normalized[sp..], " \t\r\n") };
}

fn eqIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn isPing(text: []const u8) bool {
    const n = std.mem.trim(u8, text, " \t\r\n");
    return eqIgnoreCase(n, "ping") or eqIgnoreCase(n, "/ping");
}

pub fn route(
    allocator: std.mem.Allocator,
    ctrl: control.Control,
    settings: types.Settings,
    raw_text: []const u8,
    out: *Reply,
) !void {
    _ = allocator;
    _ = settings;
    const text = std.mem.trim(u8, raw_text, " \t\r\n");
    if (text.len == 0) return;
    if (isPing(text)) return out.set("pong");

    const parts = splitCommand(text);
    const cmd = parts.cmd;

    if (eqIgnoreCase(cmd, "/help")) return out.set(helpText());
    if (eqIgnoreCase(cmd, "/status")) return out.set(statusText(ctrl));
    if (cmd.len != 0 and !eqIgnoreCase(cmd, "/term") and !eqIgnoreCase(cmd, "/keys") and
        !eqIgnoreCase(cmd, "/ai") and !eqIgnoreCase(cmd, "/stop"))
    {
        return out.set("未知命令。\n\n" ++ helpTextConst);
    }
    if (cmd.len != 0 and !eqIgnoreCase(cmd, "/stop") and parts.arg.len == 0) {
        return out.set(usageText(cmd));
    }

    if (!ctrl.isConnected()) return out.set("Phantty 当前离线，无法处理。");

    if (eqIgnoreCase(cmd, "/stop")) return stopAi(ctrl, out);
    if (eqIgnoreCase(cmd, "/term")) return sendTerminal(ctrl, parts.arg, true, out);
    if (eqIgnoreCase(cmd, "/keys")) return sendTerminal(ctrl, parts.arg, false, out);
    if (eqIgnoreCase(cmd, "/ai")) return sendAi(ctrl, parts.arg, out);
    return sendAi(ctrl, text, out);
}

fn sendAi(ctrl: control.Control, text: []const u8, out: *Reply) !void {
    const ai = ctrl.findAiSurface() orelse blk: {
        switch (ctrl.openAiAgent(AI_OPEN_TIMEOUT_MS)) {
            .no_profile => return out.set("Phantty 尚未配置 AI Chat profile。"),
            .failed => return out.set("Phantty 无法打开 AI Agent。"),
            .offline => return out.set("Phantty 当前离线，无法打开 AI Agent。"),
            .timeout => return out.set("已请求打开 AI Agent，但未等到 AI Chat tab。"),
            .opened => {},
        }
        break :blk ctrl.findAiSurface() orelse return out.set("已请求打开 AI Agent，但未等到 AI Chat tab。");
    };

    var buf = std.ArrayList(u8).init(out.text.allocator);
    defer buf.deinit();
    try buf.appendSlice(text);
    try buf.append('\r');
    if (!ctrl.sendInput(ai.id, buf.items)) return out.set("Phantty 当前离线，无法发送给 AI Agent。");
    try out.set(AI_ACK);
    out.expect_ai_progress = true;
}

fn stopAi(ctrl: control.Control, out: *Reply) !void {
    const ai = ctrl.findAiSurface() orelse return out.set("当前没有 AI Agent 可停止。");
    if (!ctrl.sendInput(ai.id, ESC)) return out.set("Phantty 当前离线，无法停止 AI Agent。");
    return out.set("已发送停止指令。");
}

fn sendTerminal(ctrl: control.Control, text: []const u8, enter: bool, out: *Reply) !void {
    const term = ctrl.findTerminalSurface() orelse return out.set("当前没有可写终端 surface。");
    var buf = std.ArrayList(u8).init(out.text.allocator);
    defer buf.deinit();
    try buf.appendSlice(text);
    if (enter) try buf.append('\r');
    if (!ctrl.sendInput(term.id, buf.items)) return out.set("Phantty 当前离线，无法发送到终端。");
    return out.set("已发送到终端。");
}

const helpTextConst =
    "Phantty 微信直连命令：\n" ++
    "/ping 验证连接\n/status 查看状态\n/ai <内容> 发送给 AI Agent\n" ++
    "/stop 停止当前 AI 处理\n/term <命令> 发送到终端并回车\n/keys <文本> 发送原始文本\n" ++
    "普通文本默认发送给 AI Agent。";

fn helpText() []const u8 {
    return helpTextConst;
}

fn statusText(ctrl: control.Control) []const u8 {
    return if (ctrl.isConnected()) "微信直连：在线" else "微信直连：离线";
}

fn usageText(cmd: []const u8) []const u8 {
    if (eqIgnoreCase(cmd, "/term")) return "用法：/term <命令>";
    if (eqIgnoreCase(cmd, "/keys")) return "用法：/keys <文本>";
    if (eqIgnoreCase(cmd, "/ai")) return "用法：/ai <内容>";
    return helpTextConst;
}
```

> Note: full-width `／` normalization is stubbed to ASCII for v1 (the TS bridge supports it; add byte-prefix handling later if needed). Tests use ASCII `/`.

- [ ] **Step 4: Run to verify it passes**

Run: `zig test src/weixin/agent.zig`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add src/weixin/agent.zig
git commit -m "feat(weixin): port command routing to local surfaces"
```

### Task 7: `src/weixin/reply_progress.zig` — AI transcript diffing

Ports `aiReplyProgress` + `parseAiSections` + helpers from `poller.ts:293-413`. Pure string processing. Reference: the transcript cases in `remote/test/server/weixin_poller.test.ts`.

**Files:**
- Create: `src/weixin/reply_progress.zig`

- [ ] **Step 1: Write the failing tests**

Append to `src/weixin/reply_progress.zig`:

```zig
const t = std.testing;

test "done when a new assistant message exists and status is idle" {
    const baseline = "You:\nhi\n";
    const current = "You:\nhi\nAI:\nthere\nStatus:\nidle\n";
    const p = progress(baseline, current);
    try t.expect(p.done);
    try t.expectEqualStrings("there", p.text);
}

test "not done while tools are running" {
    const baseline = "You:\nhi\n";
    const current = "You:\nhi\nStatus:\nrunning tools\n";
    const p = progress(baseline, current);
    try t.expect(!p.done);
    try t.expect(p.text.len != 0);
}

test "empty when nothing new" {
    const p = progress("You:\nhi\n", "You:\nhi\n");
    try t.expect(!p.done);
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `zig test src/weixin/reply_progress.zig`
Expected: FAIL — `progress` undefined.

- [ ] **Step 3: Write the implementation**

Prepend to `src/weixin/reply_progress.zig`. This is a faithful port of `aiReplyProgress`; section parsing splits on lines that are exactly a label followed by `:`.

```zig
//! AI-reply progress detection by diffing the rendered AI chat transcript
//! against a baseline. Port of poller.ts aiReplyProgress + parseAiSections.
const std = @import("std");

pub const Progress = struct { done: bool = false, text: []const u8 = "" };

const Role = enum { metadata, user, assistant, tool, reasoning };
const Section = struct { role: Role, label: []const u8, content: []const u8 };

/// Compares baseline vs current transcript. `text` borrows from `current`.
pub fn progress(baseline: []const u8, current: []const u8) Progress {
    var base_buf: [256]Section = undefined;
    var cur_buf: [256]Section = undefined;
    const base_sections = parseSections(baseline, &base_buf);
    const cur_sections = parseSections(current, &cur_buf);

    const base_msgs = filterMessages(base_sections, base_buf[base_sections.len..]);
    const cur_msgs = filterMessages(cur_sections, cur_buf[cur_sections.len..]);
    const new_msgs = afterBaseline(base_msgs, cur_msgs);
    const status = latestStatus(cur_sections);

    // last assistant message among the new ones with non-empty content
    var last_assistant: ?[]const u8 = null;
    for (new_msgs) |m| {
        if (m.role == .assistant and trim(m.content).len != 0) last_assistant = trim(m.content);
    }

    if (last_assistant) |content| {
        if (!isActiveStatus(status)) return .{ .done = true, .text = content };
    }
    if (containsIgnoreCase(status, "running tools") or hasRole(new_msgs, .tool)) {
        return .{ .done = false, .text = "还在处理中，工具调用仍在执行。" };
    }
    if (new_msgs.len != 0 or last_assistant != null) {
        return .{ .done = false, .text = "还在处理中，等待 AI 回复。" };
    }
    return .{ .done = false, .text = "" };
}

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

fn parseSections(transcript: []const u8, buf: []Section) []Section {
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, transcript, '\n');
    var current_role: ?Role = null;
    var current_label: []const u8 = "";
    var content_start: usize = 0;
    var content_end: usize = 0;
    var have_content = false;

    // We index into transcript; track offsets to slice content out.
    var line_start: usize = 0;
    while (it.next()) |line| {
        const line_len = line.len;
        const trimmed = trim(line);
        if (asLabel(trimmed)) |role| {
            if (current_role) |role_val| {
                if (count < buf.len) {
                    buf[count] = .{ .role = role_val, .label = current_label, .content = if (have_content) transcript[content_start..content_end] else "" };
                    count += 1;
                }
            }
            current_role = role;
            current_label = trimmed[0 .. trimmed.len - 1]; // strip trailing ':'
            have_content = false;
            content_start = line_start + line_len + 1;
            content_end = content_start;
        } else if (current_role != null) {
            content_end = line_start + line_len;
            have_content = true;
        }
        line_start += line_len + 1;
    }
    if (current_role) |role_val| {
        if (count < buf.len) {
            buf[count] = .{ .role = role_val, .label = current_label, .content = if (have_content) transcript[content_start..content_end] else "" };
            count += 1;
        }
    }
    return buf[0..count];
}

/// A label line is exactly one of the known labels followed by ':'.
fn asLabel(line: []const u8) ?Role {
    if (line.len < 2 or line[line.len - 1] != ':') return null;
    const name = line[0 .. line.len - 1];
    if (eq(name, "You") or eq(name, "User")) return .user;
    if (eq(name, "AI") or eq(name, "Assistant")) return .assistant;
    if (eq(name, "Tool")) return .tool;
    if (eq(name, "Reasoning")) return .reasoning;
    if (eq(name, "Model") or eq(name, "Status")) return .metadata;
    return null;
}

fn filterMessages(sections: []const Section, out: []Section) []Section {
    var n: usize = 0;
    for (sections) |s| {
        if (s.role == .user or s.role == .assistant or s.role == .tool) {
            out[n] = s;
            n += 1;
        }
    }
    return out[0..n];
}

fn afterBaseline(baseline: []const Section, current: []const Section) []const Section {
    if (baseline.len == 0) return current;
    if (current.len == 0) return current[0..0];
    const max_overlap = @min(baseline.len, current.len);
    var overlap = max_overlap;
    while (overlap > 0) : (overlap -= 1) {
        const base_start = baseline.len - overlap;
        var matched = true;
        var i: usize = 0;
        while (i < overlap) : (i += 1) {
            if (baseline[base_start + i].role != current[i].role or
                !std.mem.eql(u8, baseline[base_start + i].content, current[i].content))
            {
                matched = false;
                break;
            }
        }
        if (matched) return current[overlap..];
    }
    return current;
}

fn latestStatus(sections: []const Section) []const u8 {
    var i: usize = sections.len;
    while (i > 0) : (i -= 1) {
        if (eq(sections[i - 1].label, "Status")) return trim(sections[i - 1].content);
    }
    return "";
}

fn isActiveStatus(status: []const u8) bool {
    return containsIgnoreCase(status, "running tools") or containsIgnoreCase(status, "thinking") or
        containsIgnoreCase(status, "streaming") or containsIgnoreCase(status, "stopping");
}

fn hasRole(msgs: []const Section, role: Role) bool {
    for (msgs) |m| if (m.role == role) return true;
    return false;
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}
```

> Note: section parsing here borrows content slices from the input transcript and uses fixed-size stack buffers (256 sections). If a transcript exceeds that, older sections are dropped — acceptable for progress detection. Verify the three tests pass; adjust slice-offset arithmetic if the toolchain's `splitScalar` accounting differs.

- [ ] **Step 4: Run to verify it passes**

Run: `zig test src/weixin/reply_progress.zig`
Expected: PASS (3 tests). If offset math is off, fix until green before committing.

- [ ] **Step 5: Commit**

```bash
git add src/weixin/reply_progress.zig
git commit -m "feat(weixin): port AI-reply progress diffing"
```

---

## Phase 2 — ilink transport (cross-platform compile; logic via fakes)

### Task 8: `src/weixin/ilink_codec.zig` — request/response JSON

**Files:**
- Create: `src/weixin/ilink_codec.zig`

- [ ] **Step 1: Write the failing tests**

Append to `src/weixin/ilink_codec.zig`:

```zig
const t = std.testing;

test "builds a getupdates body with the channel version" {
    const body = try buildGetUpdatesBody(t.allocator, "BUF==");
    defer t.allocator.free(body);
    try t.expect(std.mem.indexOf(u8, body, "\"get_updates_buf\":\"BUF==\"") != null);
    try t.expect(std.mem.indexOf(u8, body, "\"channel_version\":\"1.0.2\"") != null);
}

test "parses a getupdates response into typed messages" {
    const json =
        \\{"ret":0,"longpolling_timeout_ms":1500,"get_updates_buf":"NEXT",
        \\"msgs":[{"from_user_id":"u1","context_token":"ctx",
        \\"item_list":[{"type":1,"text_item":{"text":"hi"}}]}]}
    ;
    var parsed = try parseGetUpdates(t.allocator, json);
    defer parsed.deinit();
    try t.expectEqual(@as(i64, 1500), parsed.value.longpolling_timeout_ms);
    try t.expectEqualStrings("NEXT", parsed.value.get_updates_buf);
    try t.expectEqual(@as(usize, 1), parsed.value.msgs.len);
    try t.expectEqualStrings("u1", parsed.value.msgs[0].from_user_id);
    try t.expectEqualStrings("hi", parsed.value.msgs[0].item_list[0].text);
}

test "maps qrcode status strings to the enum" {
    try t.expectEqual(types.QrStatusKind.scaned, statusKindFromString("scaned"));
    try t.expectEqual(types.QrStatusKind.confirmed, statusKindFromString("confirmed"));
    try t.expectEqual(types.QrStatusKind.unknown, statusKindFromString("nonsense"));
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `zig test src/weixin/ilink_codec.zig`
Expected: FAIL — symbols undefined.

- [ ] **Step 3: Write the implementation**

Prepend to `src/weixin/ilink_codec.zig`. Parsing uses `std.json` into wire structs, then maps into `types`. The `Parsed*` wrappers own an arena so callers free with `deinit`.

```zig
//! ilink JSON request builders and response parsers. Pure (std.json).
const std = @import("std");
const types = @import("types.zig");

pub const CHANNEL_VERSION = "1.0.2";
pub const BOT_TYPE = "3";
pub const DEFAULT_BASE_URL = "https://ilinkai.weixin.qq.com";

pub fn buildGetUpdatesBody(allocator: std.mem.Allocator, buf: []const u8) ![]u8 {
    const Body = struct {
        get_updates_buf: []const u8,
        base_info: struct { channel_version: []const u8 },
    };
    return std.json.stringifyAlloc(allocator, Body{
        .get_updates_buf = buf,
        .base_info = .{ .channel_version = CHANNEL_VERSION },
    }, .{});
}

pub fn buildSendTextBody(
    allocator: std.mem.Allocator,
    to_user_id: []const u8,
    text: []const u8,
    context_token: []const u8,
    client_id: []const u8,
) ![]u8 {
    const Body = struct {
        msg: struct {
            to_user_id: []const u8,
            client_id: []const u8,
            message_type: i64 = 2,
            message_state: i64 = 2,
            context_token: []const u8,
            item_list: []const struct {
                type: i64 = 1,
                text_item: struct { text: []const u8 },
            },
        },
        base_info: struct { channel_version: []const u8 },
    };
    const items = [_]@TypeOf(@as(Body, undefined).msg.item_list[0]){
        .{ .text_item = .{ .text = text } },
    };
    return std.json.stringifyAlloc(allocator, Body{
        .msg = .{
            .to_user_id = to_user_id,
            .client_id = client_id,
            .context_token = context_token,
            .item_list = &items,
        },
        .base_info = .{ .channel_version = CHANNEL_VERSION },
    }, .{});
}

pub fn statusKindFromString(s: []const u8) types.QrStatusKind {
    if (std.mem.eql(u8, s, "wait")) return .wait;
    if (std.mem.eql(u8, s, "scaned")) return .scaned;
    if (std.mem.eql(u8, s, "confirmed")) return .confirmed;
    if (std.mem.eql(u8, s, "expired")) return .expired;
    return .unknown;
}

// --- response parsing ---

pub fn ParsedGetUpdates(comptime T: type) type {
    return struct {
        arena: *std.heap.ArenaAllocator,
        value: T,
        pub fn deinit(self: *@This()) void {
            const child = self.arena.child_allocator;
            self.arena.deinit();
            child.destroy(self.arena);
        }
    };
}

const WireItem = struct {
    type: i64 = 0,
    text_item: ?struct { text: []const u8 = "" } = null,
    voice_item: ?struct { text: []const u8 = "" } = null,
};
const WireMsg = struct {
    from_user_id: []const u8 = "",
    to_user_id: []const u8 = "",
    context_token: []const u8 = "",
    group_id: []const u8 = "",
    item_list: []const WireItem = &.{},
};
const WireUpdates = struct {
    ret: i64 = 0,
    errcode: i64 = 0,
    longpolling_timeout_ms: i64 = 0,
    get_updates_buf: []const u8 = "",
    msgs: []const WireMsg = &.{},
};

pub fn parseGetUpdates(allocator: std.mem.Allocator, json: []const u8) !ParsedGetUpdates(types.GetUpdatesResult) {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer {
        arena.deinit();
        allocator.destroy(arena);
    }
    const a = arena.allocator();
    const wire = try std.json.parseFromSliceLeaky(WireUpdates, a, json, .{ .ignore_unknown_fields = true });

    const msgs = try a.alloc(types.Message, wire.msgs.len);
    for (wire.msgs, 0..) |wm, mi| {
        const items = try a.alloc(types.MessageItem, wm.item_list.len);
        for (wm.item_list, 0..) |wi, ii| {
            items[ii] = .{
                .type = wi.type,
                .text = if (wi.text_item) |x| x.text else "",
                .voice_text = if (wi.voice_item) |x| x.text else "",
            };
        }
        msgs[mi] = .{
            .from_user_id = wm.from_user_id,
            .to_user_id = wm.to_user_id,
            .context_token = wm.context_token,
            .group_id = wm.group_id,
            .item_list = items,
        };
    }
    return .{ .arena = arena, .value = .{
        .ret = wire.ret,
        .errcode = wire.errcode,
        .longpolling_timeout_ms = wire.longpolling_timeout_ms,
        .get_updates_buf = wire.get_updates_buf,
        .msgs = msgs,
    } };
}
```

> Note: `std.json` API names in Zig 0.15.2 may differ slightly (`stringifyAlloc` vs `Stringify`). If so, adapt the calls; the tests pin behavior. The anonymous-struct trick in `buildSendTextBody` for `item_list` element type may need extracting to a named struct if the compiler rejects `@TypeOf(... .item_list[0])` — extract a `const SendItem = struct {...}` and reuse it.

- [ ] **Step 4: Run to verify it passes**

Run: `zig test src/weixin/ilink_codec.zig`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add src/weixin/ilink_codec.zig
git commit -m "feat(weixin): add ilink JSON codec"
```

### Task 9: `src/weixin/ilink_client.zig` — HTTP over `std.http.Client`

Compiles cross-platform; the network methods can't be unit-tested on the Linux host (compile-only, per the project's test note). Define a `ClientApi` interface so the poller stays testable with fakes.

**Files:**
- Create: `src/weixin/ilink_client.zig`

- [ ] **Step 1: Write the implementation (no network test on this host)**

```zig
//! ilink HTTP client over std.http.Client. Network calls are compile-only on
//! the Linux dev host; logic that consumes this goes through ClientApi.
const std = @import("std");
const codec = @import("ilink_codec.zig");
const types = @import("types.zig");

pub const ClientApi = struct {
    ctx: *anyopaque,
    vtable: *const VTable,
    pub const VTable = struct {
        get_updates: *const fn (ctx: *anyopaque, buf: []const u8, out_arena: std.mem.Allocator) anyerror!types.GetUpdatesResult,
        send_text: *const fn (ctx: *anyopaque, to_user_id: []const u8, text: []const u8, context_token: []const u8) anyerror!void,
    };
    pub fn getUpdates(self: ClientApi, buf: []const u8, out_arena: std.mem.Allocator) !types.GetUpdatesResult {
        return self.vtable.get_updates(self.ctx, buf, out_arena);
    }
    pub fn sendText(self: ClientApi, to_user_id: []const u8, text: []const u8, context_token: []const u8) !void {
        return self.vtable.send_text(self.ctx, to_user_id, text, context_token);
    }
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    http: std.http.Client,
    base_url: []const u8,
    token: []const u8,
    rng: std.Random.DefaultPrng,

    pub fn init(allocator: std.mem.Allocator, base_url: []const u8, token: []const u8) Client {
        return .{
            .allocator = allocator,
            .http = .{ .allocator = allocator },
            .base_url = base_url,
            .token = token,
            .rng = std.Random.DefaultPrng.init(@bitCast(std.time.milliTimestamp())),
        };
    }
    pub fn deinit(self: *Client) void {
        self.http.deinit();
    }

    fn headers(self: *Client, uin_buf: []u8) std.http.Client.Request.Headers {
        // X-WECHAT-UIN: base64 of a random uint string. Compute into uin_buf.
        _ = uin_buf;
        _ = self;
        // Implementation detail filled during compile iteration; see Step 2.
        return .{};
    }

    /// GET /ilink/bot/get_bot_qrcode?bot_type=3
    pub fn getBotQrcode(self: *Client, arena: std.mem.Allocator) !types.QrCode {
        return self.getJson(types.QrCode, arena, "/ilink/bot/get_bot_qrcode?bot_type=" ++ codec.BOT_TYPE, qrCodeFromJson);
    }

    /// GET /ilink/bot/get_qrcode_status?qrcode=...
    pub fn getQrcodeStatus(self: *Client, arena: std.mem.Allocator, qrcode: []const u8) !types.QrStatus {
        const path = try std.fmt.allocPrint(arena, "/ilink/bot/get_qrcode_status?qrcode={s}", .{qrcode});
        return self.getJson(types.QrStatus, arena, path, qrStatusFromJson);
    }

    /// POST /ilink/bot/getupdates  (≈35s long-poll)
    pub fn getUpdates(self: *Client, arena: std.mem.Allocator, buf: []const u8) !types.GetUpdatesResult {
        const body = try codec.buildGetUpdatesBody(arena, buf);
        const resp = try self.postRaw(arena, "/ilink/bot/getupdates", body);
        var parsed = try codec.parseGetUpdates(arena, resp);
        return parsed.value; // arena owns it; freed when arena resets
    }

    /// POST /ilink/bot/sendmessage
    pub fn sendText(self: *Client, to_user_id: []const u8, text: []const u8, context_token: []const u8) !void {
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const client_id = try std.fmt.allocPrint(arena, "phantty-weixin-{d}-{d}", .{
            std.time.milliTimestamp(), self.rng.random().int(u32),
        });
        const body = try codec.buildSendTextBody(arena, to_user_id, text, context_token, client_id);
        _ = try self.postRaw(arena, "/ilink/bot/sendmessage", body);
    }

    // --- the std.http plumbing below is filled in during compile iteration ---
    fn getJson(self: *Client, comptime T: type, arena: std.mem.Allocator, path: []const u8, comptime mapFn: anytype) !T {
        const raw = try self.fetch(arena, .GET, path, null);
        return mapFn(arena, raw);
    }
    fn postRaw(self: *Client, arena: std.mem.Allocator, path: []const u8, body: []const u8) ![]u8 {
        return self.fetch(arena, .POST, path, body);
    }
    fn fetch(self: *Client, arena: std.mem.Allocator, method: std.http.Method, path: []const u8, body: ?[]const u8) ![]u8 {
        const url = try std.fmt.allocPrint(arena, "{s}{s}", .{ self.base_url, path });
        var buf = std.ArrayList(u8).init(arena);
        const result = try self.http.fetch(.{
            .method = method,
            .location = .{ .url = url },
            .payload = body,
            .response_storage = .{ .dynamic = &buf },
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json" },
                .{ .name = "AuthorizationType", .value = "ilink_bot_token" },
                .{ .name = "Authorization", .value = try std.fmt.allocPrint(arena, "Bearer {s}", .{self.token}) },
            },
        });
        if (result.status != .ok) return error.IlinkHttpStatus;
        return buf.toOwnedSlice();
    }

    /// Adapter exposing this Client as a ClientApi for the poller.
    pub fn api(self: *Client) ClientApi {
        return .{ .ctx = self, .vtable = &.{
            .get_updates = apiGetUpdates,
            .send_text = apiSendText,
        } };
    }
    fn apiGetUpdates(ctx: *anyopaque, buf: []const u8, out_arena: std.mem.Allocator) anyerror!types.GetUpdatesResult {
        return @as(*Client, @ptrCast(@alignCast(ctx))).getUpdates(out_arena, buf);
    }
    fn apiSendText(ctx: *anyopaque, to_user_id: []const u8, text: []const u8, context_token: []const u8) anyerror!void {
        return @as(*Client, @ptrCast(@alignCast(ctx))).sendText(to_user_id, text, context_token);
    }
};

fn qrCodeFromJson(arena: std.mem.Allocator, json: []const u8) !types.QrCode {
    const W = struct { ret: i64 = 0, qrcode: []const u8 = "", qrcode_img_content: []const u8 = "" };
    const w = try std.json.parseFromSliceLeaky(W, arena, json, .{ .ignore_unknown_fields = true });
    return .{ .ret = w.ret, .qrcode = w.qrcode, .qrcode_img_content = w.qrcode_img_content };
}
fn qrStatusFromJson(arena: std.mem.Allocator, json: []const u8) !types.QrStatus {
    const W = struct {
        ret: i64 = 0,
        status: []const u8 = "",
        bot_token: []const u8 = "",
        baseurl: []const u8 = "",
        ilink_bot_id: []const u8 = "",
        ilink_user_id: []const u8 = "",
    };
    const w = try std.json.parseFromSliceLeaky(W, arena, json, .{ .ignore_unknown_fields = true });
    return .{
        .ret = w.ret,
        .status = codec.statusKindFromString(w.status),
        .bot_token = w.bot_token,
        .base_url = w.baseurl,
        .bot_id = w.ilink_bot_id,
        .user_id = w.ilink_user_id,
    };
}
```

- [ ] **Step 2: Compile and iterate on the `std.http` API**

Run: `zig build`
Expected: this is the iteration point. Fix `std.http.Client.fetch` option names, header struct shape, and the `X-WECHAT-UIN` header (base64 of a random uint string — add it to `extra_headers`) to match Zig 0.15.2. The QR-image header `iLink-App-ClientVersion: 1` is needed on `getQrcodeStatus`; thread an `extra header` param through `fetch` if required. Keep iterating until `zig build` succeeds.

- [ ] **Step 3: Commit**

```bash
git add src/weixin/ilink_client.zig
git commit -m "feat(weixin): add ilink HTTP client (std.http)"
```

### Task 10: `src/weixin/poller.zig` — update processing + poll loop

`processUpdates` is pure and testable with fakes (ports `processWeixinUpdates`, `poller.ts:59-83`). The `Poller` thread loop ports the `tick`/generation/staleness machinery; it's compile-checked here and exercised end-to-end on Windows.

**Files:**
- Create: `src/weixin/poller.zig`

- [ ] **Step 1: Write the failing test for `processUpdates`**

Append to `src/weixin/poller.zig`:

```zig
const t = std.testing;

const Captured = struct {
    sent: std.ArrayList([]u8),
    routed: std.ArrayList([]u8),
    fn init() Captured {
        return .{ .sent = std.ArrayList([]u8).init(t.allocator), .routed = std.ArrayList([]u8).init(t.allocator) };
    }
    fn deinit(self: *Captured) void {
        for (self.sent.items) |s| t.allocator.free(s);
        for (self.routed.items) |s| t.allocator.free(s);
        self.sent.deinit();
        self.routed.deinit();
    }
};

test "processUpdates routes accepted text and sends replies" {
    var cap = Captured.init();
    defer cap.deinit();

    const RouteCtx = struct {
        cap: *Captured,
        fn route(ctx: *anyopaque, text: []const u8, reply: *std.ArrayList(u8)) anyerror!bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            try self.cap.routed.append(try t.allocator.dupe(u8, text));
            try reply.appendSlice("ok");
            return false; // no AI progress
        }
    };
    const SendCtx = struct {
        cap: *Captured,
        fn send(ctx: *anyopaque, to: []const u8, text: []const u8, _: []const u8) anyerror!void {
            _ = to;
            const self: *@This() = @ptrCast(@alignCast(ctx));
            try self.cap.sent.append(try t.allocator.dupe(u8, text));
        }
    };
    var rctx = RouteCtx{ .cap = &cap };
    var sctx = SendCtx{ .cap = &cap };

    const msgs = [_]types.Message{
        .{ .from_user_id = "u1", .context_token = "c", .item_list = &.{.{ .type = 1, .text = "hi" }} },
        .{ .from_user_id = "u1", .group_id = "g", .item_list = &.{.{ .type = 1, .text = "ignored" }} }, // group → skip
    };

    try processUpdates(.{
        .owner = "u1",
        .account_id = "",
        .messages = &msgs,
        .route_ctx = &rctx,
        .route_fn = RouteCtx.route,
        .send_ctx = &sctx,
        .send_fn = SendCtx.send,
    });

    try t.expectEqual(@as(usize, 1), cap.routed.items.len);
    try t.expectEqualStrings("hi", cap.routed.items[0]);
    try t.expectEqual(@as(usize, 1), cap.sent.items.len);
    try t.expectEqualStrings("ok", cap.sent.items[0]);
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `zig test src/weixin/poller.zig`
Expected: FAIL — `processUpdates` undefined.

- [ ] **Step 3: Implement `processUpdates` (the testable core)**

Prepend to `src/weixin/poller.zig`:

```zig
//! WeChat poll loop. processUpdates is the pure core; Poller wraps it in a
//! thread with generation/staleness cancellation (port of poller.ts).
const std = @import("std");
const types = @import("types.zig");
const binding = @import("binding.zig");

pub const ProcessInput = struct {
    owner: []const u8,
    account_id: []const u8,
    messages: []const types.Message,
    route_ctx: *anyopaque,
    /// returns true if the caller should begin AI-progress streaming
    route_fn: *const fn (ctx: *anyopaque, text: []const u8, reply: *std.ArrayList(u8)) anyerror!bool,
    send_ctx: *anyopaque,
    send_fn: *const fn (ctx: *anyopaque, to_user_id: []const u8, text: []const u8, context_token: []const u8) anyerror!void,
};

/// Mirror of processWeixinUpdates: filter, extract, route, reply.
pub fn processUpdates(input: ProcessInput) !void {
    for (input.messages) |msg| {
        if (!binding.shouldHandle(input.owner, input.account_id, msg).ok) continue;
        const text = binding.extractText(msg);
        if (text.len == 0) continue;

        var reply = std.ArrayList(u8).init(std.heap.page_allocator);
        defer reply.deinit();
        _ = input.route_fn(input.route_ctx, text, &reply) catch continue;

        const trimmed = std.mem.trim(u8, reply.items, " \t\r\n");
        if (trimmed.len != 0) {
            input.send_fn(input.send_ctx, msg.from_user_id, trimmed, msg.context_token) catch {};
        }
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `zig test src/weixin/poller.zig`
Expected: PASS (1 test).

- [ ] **Step 5: Add the `Poller` thread loop (compile-checked)**

Append the loop after `processUpdates`. It ports the `tick` flow: load binding/settings, long-poll `getUpdates`, handle `errcode == -14` (disable), call `processUpdates`, persist `get_updates_buf`, reschedule with `longpolling_timeout_ms`. It uses an injected `ClientApi` (Task 9) and a `Control` (Task 5), and runs on a `std.Thread` with an atomic stop flag (mirror `remote_client.zig:85,113,117-123`).

```zig
const ClientApi = @import("ilink_client.zig").ClientApi;
const control_mod = @import("control.zig");

pub const SESSION_EXPIRED_ERRCODE: i64 = -14;

pub const Poller = struct {
    allocator: std.mem.Allocator,
    client: ClientApi,
    control: control_mod.Control,
    owner: []const u8,
    account_id: []const u8,
    sync_buf: []u8,
    on_sync_buf: *const fn (ctx: *anyopaque, buf: []const u8) void,
    on_sync_ctx: *anyopaque,
    stop_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,

    pub fn start(self: *Poller) !void {
        self.thread = try std.Thread.spawn(.{}, threadMain, .{self});
    }
    pub fn stop(self: *Poller) void {
        self.stop_requested.store(true, .release);
        if (self.thread) |th| {
            th.join();
            self.thread = null;
        }
    }

    fn threadMain(self: *Poller) void {
        while (!self.stop_requested.load(.acquire)) {
            self.tickOnce() catch {
                std.Thread.sleep(5 * std.time.ns_per_s);
                continue;
            };
        }
    }

    fn tickOnce(self: *Poller) !void {
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const updates = try self.client.getUpdates(self.sync_buf, arena);
        if (updates.errcode == SESSION_EXPIRED_ERRCODE) {
            self.stop_requested.store(true, .release);
            return;
        }
        // route_fn / send_fn adapters bind to self.control and self.client.
        // (Implemented during integration; see Task 13.)
        // For now, process with no-op routing to keep the loop honest.
        _ = updates;
        if (self.stop_requested.load(.acquire)) return;
    }
};
```

> Note: the `route_fn`/`send_fn` adapters that bridge `processUpdates` to `self.control` (agent.route) and `self.client.sendText`, plus AI-progress streaming via `reply_progress` at 10/30/60/120s checkpoints, are wired in Task 13 where the live `Control` exists. This task only needs `zig build` to succeed.

- [ ] **Step 6: Compile**

Run: `zig build`
Expected: builds. Iterate on `std.Thread`/atomics API names if needed.

- [ ] **Step 7: Register pure modules in the test binary and commit**

Add to `src/test_main.zig` (near the other `_ = @import(...)` lines, ~line 656):

```zig
    _ = @import("weixin/types.zig");
    _ = @import("weixin/state_store.zig");
    _ = @import("weixin/binding.zig");
    _ = @import("weixin/control.zig");
    _ = @import("weixin/agent.zig");
    _ = @import("weixin/reply_progress.zig");
    _ = @import("weixin/ilink_codec.zig");
    _ = @import("weixin/ilink_client.zig");
    _ = @import("weixin/poller.zig");
```

Run: `zig build` then commit.

```bash
git add src/weixin/poller.zig src/test_main.zig
git commit -m "feat(weixin): add poll loop and register weixin test modules"
```

---

## Phase 3 — `LocalControl` over App/AppWindow (Windows-bound integration)

### Task 11: Implement the live `Control` accessors on the window

The poller's `Control` must resolve the focused window's AI-chat surface, send input, open the AI agent, and read the transcript. The remote path already exposes the building blocks in `src/AppWindow.zig`: `remoteAiSurfaceId(tab_index)` (line 1793), `registerRemoteAiInputSink` (1799) with `thread_message.postPointer(.remote_ai_input, ...)` (1823), and `remoteAiAgentOpen` (1830) using `thread_message.sendPointer(.remote_open_ai_agent, ...)`. Reuse these.

**Files:**
- Modify: `src/AppWindow.zig` (add `findAiChatSurface`, `latestAiChatTranscript`, `onLayout` analog or a snapshot getter)
- Modify: `src/App.zig` (expose a `weixinControl(self: *App) control.Control` builder)

- [ ] **Step 1: Investigate the AI transcript source**

The remote worker reconstructs the transcript from published surface output. Locally, find the in-memory transcript on the AI chat session. Run:

```bash
grep -n "transcript\|renderTranscript\|Session\|aiChatSurface\|ai_chat" src/AppWindow.zig | head -40
```

Identify the function that yields the rendered "You:/AI:/Status:" text for the focused tab's AI chat. If none exists, add `pub fn aiChatTranscriptAlloc(self: *AppWindow, allocator) ?[]u8` that renders the focused AI session via `ai_chat.zig` into the same label format `reply_progress.zig` parses.

- [ ] **Step 2: Add the surface/transcript accessors**

In `src/AppWindow.zig`, add (adapting names to what Step 1 found):

```zig
/// Returns the focused tab's AI chat surface id/title if one is open.
pub fn weixinFindAiSurface(self: *AppWindow) ?weixin_control.Surface {
    const idx = self.focusedTabIndex() orelse return null;
    if (!self.tabHasAiChat(idx)) return null;
    return .{ .id = remoteAiSurfaceId(idx), .title = self.tabs.items[idx].getTitle() };
}

/// Returns the focused tab's default writable terminal surface id/title.
pub fn weixinFindTerminalSurface(self: *AppWindow) ?weixin_control.Surface {
    // reuse the same surface id scheme the renderer/input path uses
    ...
}

/// Renders the focused AI chat transcript in the label format reply_progress
/// expects. Caller owns the returned slice.
pub fn weixinTranscriptAlloc(self: *AppWindow, allocator: std.mem.Allocator) ?[]u8 {
    ...
}
```

Add `const weixin_control = @import("weixin/control.zig");` to the imports.

- [ ] **Step 3: Build the `Control` in `App`**

In `src/App.zig`, add a builder that fills the vtable by delegating to the focused window. Input delivery reuses the remote marshalling: for AI input, post `.remote_ai_input` (`thread_message.postPointer`); for AI-agent open, send `.remote_open_ai_agent`. `send_input` returns `false` when no window/native handle is available (offline).

```zig
const weixin_control = @import("weixin/control.zig");

pub fn weixinControl(self: *App) weixin_control.Control {
    return .{ .ctx = self, .vtable = &weixin_control_vtable };
}

const weixin_control_vtable = weixin_control.Control.VTable{
    .is_connected = wxIsConnected,
    .find_ai_surface = wxFindAi,
    .find_terminal_surface = wxFindTerm,
    .open_ai_agent = wxOpenAi,
    .send_input = wxSendInput,
    .latest_transcript = wxTranscript,
};
// each wx* fn: lock app.mutex, pick the first window with a native handle,
// delegate to the AppWindow accessors / thread_message marshalling above.
```

- [ ] **Step 4: Compile (Windows build)**

Run: `zig build`
Expected: builds on Windows. This task is integration glue — iterate against the compiler. It is not unit-tested on the Linux host (GUI is Windows-only); verify it compiles via `zig build` and defer behavioral verification to the manual Windows smoke test in Task 15.

- [ ] **Step 5: Commit**

```bash
git add src/App.zig src/AppWindow.zig
git commit -m "feat(weixin): expose live Control over focused window"
```

---

## Phase 4 — Controller, lifecycle, mutual exclusion

### Task 12: `src/weixin/controller.zig` — owns the thread and wiring

**Files:**
- Create: `src/weixin/controller.zig`

- [ ] **Step 1: Implement the controller**

It loads the binding via `state_store`, builds an `ilink_client.Client` + its `ClientApi`, constructs a `Poller`, and wires the `route_fn`/`send_fn` adapters from Task 10's note: `route_fn` calls `agent.route(allocator, control, settings, text, &reply)` and returns `reply.expect_ai_progress`; when true, the controller starts `reply_progress`-based streaming using `control.latestTranscript()` at 10/30/60/120s checkpoints, clamped to `settings.reply_timeout_ms`. `send_fn` calls `client.sendText`. On bind: when `binding.ownerForBind` returns a user_id, persist it via `state_store.save`.

```zig
const std = @import("std");
const types = @import("types.zig");
const state_store = @import("state_store.zig");
const ilink = @import("ilink_client.zig");
const poller = @import("poller.zig");
const agent = @import("agent.zig");
const reply_progress = @import("reply_progress.zig");
const control_mod = @import("control.zig");

pub const Controller = struct {
    allocator: std.mem.Allocator,
    state_path: []const u8,
    control: control_mod.Control,
    settings: types.Settings,
    client: ?ilink.Client = null,
    poll: ?poller.Poller = null,
    // ... login state for the QR panel ...

    pub fn create(allocator, state_path, control, settings) !*Controller { ... }
    pub fn destroy(self) void { ... }

    /// Begins QR login: getBotQrcode → poll status → on confirmed persist token + start().
    pub fn startLogin(self: *Controller) !void { ... }

    /// Starts the poll loop using a persisted token.
    pub fn start(self: *Controller) !void { ... }

    pub fn stop(self: *Controller) void { ... }

    /// Clears owner + token and stops.
    pub fn unbind(self: *Controller) !void { ... }
};
```

- [ ] **Step 2: Compile**

Run: `zig build`
Expected: builds. Iterate on the wiring until the route/send adapters and progress streaming compile.

- [ ] **Step 3: Commit**

```bash
git add src/weixin/controller.zig
git commit -m "feat(weixin): add controller wiring poller, agent, progress"
```

### Task 13: App construction + mutual-exclusion guard + status

**Files:**
- Modify: `src/App.zig` (add a `weixin_controller: ?*weixin.Controller` field near `remote_client`; construct in init after `startRemoteClient`; destroy in `deinit` near line 893; compute the state file path)

- [ ] **Step 1: Add the field and a `startWeixinController` helper**

Mirror `startRemoteClient` (`src/App.zig:253`). Guard:

```zig
fn startWeixinController(app: *App, cfg: *const Config, remote_active: bool) ?*weixin.Controller {
    if (!cfg.@"weixin-direct-enabled") return null;
    if (remote_active) {
        std.debug.print("weixin-direct disabled: remote-enabled takes precedence\n", .{});
        return null;
    }
    const state_path = weixinStatePath(app.allocator) catch return null; // e.g. <state dir>/weixin.json via platform/dirs.zig
    const settings = types.Settings{
        .enabled = true,
        .reply_timeout_ms = std.math.clamp(cfg.@"weixin-reply-timeout-ms", 5000, 180000),
        .allowed_user = cfg.@"weixin-allowed-user" orelse "",
    };
    return weixin.Controller.create(app.allocator, state_path, app.weixinControl(), settings) catch null;
}
```

Wire in `App` init: compute `remote_active = remote_client_ptr != null;` then `.weixin_controller = startWeixinController(app, &cfg, remote_active),` and in `deinit` call `if (self.weixin_controller) |c| c.destroy();`.

> Use `src/platform/dirs.zig` for the state directory (the same module the app uses for per-user data). `weixinStatePath` joins that dir + `"weixin.json"`.

- [ ] **Step 2: Surface status**

`/status` text already comes from `agent.statusText`. Extend it to also report whether a persisted owner exists (pass that in via `Control` or settings). Add a one-line startup log when the controller starts/declines.

- [ ] **Step 3: Compile**

Run: `zig build`
Expected: builds on Windows.

- [ ] **Step 4: Commit**

```bash
git add src/App.zig
git commit -m "feat(weixin): construct controller with remote mutual exclusion"
```

---

## Phase 5 — QR login panel (Windows)

### Task 14: `src/weixin/qr_panel.zig`

**Files:**
- Create: `src/weixin/qr_panel.zig`
- Modify: the command palette / action table to add **"Connect WeChat"** and **"WeChat: Unbind"** entries; a keybind is optional.

- [ ] **Step 1: Find the panel + image-decode patterns**

```bash
grep -n "pub fn\|decode\|Image\|png\|qr" src/image_decoder.zig | head
sed -n '1,60p' src/markdown_preview_panel.zig
grep -rn "command_center\|action\|palette\|Command\b" src/command_center_state.zig | head
```

- [ ] **Step 2: Implement the panel**

The panel holds the QR image (decode `qrcode_img_content` base64 → PNG → `image_decoder`) or renders the `qrcode` string as a QR if only a URL is returned, plus status text (`等待扫码 / 已扫码 / 已确认 / 已过期`). It polls `controller` login state; on `confirmed` it closes; on `expired` it offers retry. Model it on `markdown_preview_panel.zig`'s lifecycle (open/draw/close) found in Step 1.

> If only `qrcode` (a URL/string) is returned and no inline image, v1 may render the string for the user to long-press, or generate a QR bitmap — pick based on what the live API returns during the Windows smoke test (Task 15).

- [ ] **Step 3: Wire the actions**

"Connect WeChat" → `app.weixin_controller.?.startLogin()` and open the panel. "WeChat: Unbind" → `app.weixin_controller.?.unbind()`.

- [ ] **Step 4: Compile**

Run: `zig build`
Expected: builds on Windows.

- [ ] **Step 5: Commit**

```bash
git add src/weixin/qr_panel.zig src/command_center_state.zig
git commit -m "feat(weixin): add QR login panel and actions"
```

---

## Phase 6 — End-to-end verification (Windows)

### Task 15: Manual smoke test on Windows

This feature's runtime is Windows-only; the Linux host only compiles + runs the pure-module `zig test`s. Do a manual smoke test on a Windows build.

- [ ] **Step 1: Build release**

Run: `zig build -Doptimize=ReleaseFast` (on Windows)

- [ ] **Step 2: Configure**

Set in the config file: `weixin-direct-enabled = true`, `remote-enabled = false`. Launch Phantty.

- [ ] **Step 3: Login**

Trigger **"Connect WeChat"**. Confirm the QR panel shows, scan with WeChat, and verify the panel closes on `confirmed` and a `weixin.json` (mode 0600) appears in the state dir with a `bot_token`.

- [ ] **Step 4: Control**

From the bound WeChat account, send `ping` (expect `pong`), `/status`, a plain message (expect it reaches the AI chat and an ack + progress replies arrive), `/term ls` (expect terminal runs `ls`), `/stop`. From a *different* account, send a message and confirm it is ignored.

- [ ] **Step 5: Mutual exclusion + expiry**

Set both `remote-enabled` and `weixin-direct-enabled` true; confirm the startup log says remote wins and direct is disabled. Separately, let the session expire (or simulate errcode −14) and confirm the loop stops cleanly.

- [ ] **Step 6: Final commit**

```bash
git add -A
git commit -m "test(weixin): document Windows smoke test results"
```

---

## Self-Review notes

- **Spec coverage:** §Module layout → Tasks 2–14; §Login flow → Tasks 9,12,14; §Shared control core → Tasks 5,11; §Config/persistence → Tasks 1,3,13; §Authorization → Tasks 4,12; §QR panel → Task 14; §Threading → Tasks 10,12; §Error handling (−14, backoff, expiry) → Tasks 10,12,15; §Testing → Tasks 3,4,6,8,10; §Phasing → matches Phases 0–6; §Non-goals (media, multi-tab) → not implemented (correct).
- **Layered platform decision:** Phases 0–2 compile + `zig test` on any OS (fits the Linux host); Phases 3–6 are Windows-bound integration verified via `zig build` + the Task 15 smoke test.
- **Honesty flag:** Tasks 9–14 contain skeletons with real signatures/integration points but require compile iteration against Zig 0.15.2's `std.http`/`std.json`/GUI APIs; they are explicitly marked "compile and iterate," not asserted as compiling verbatim. The pure-logic Tasks 1–8/10-core are full TDD with `zig test`.
