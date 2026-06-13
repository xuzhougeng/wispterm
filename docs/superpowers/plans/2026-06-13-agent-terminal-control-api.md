# Agent Terminal Control API (`wisptermctl`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give external agents (Claude Code / Codex CLI / scripts) a local, authenticated way to list WispTerm panes, read terminal text, and send input — the `wisptermctl` MVP from issue #173.

**Architecture:** An in-process localhost TCP listener (`std.net`, all three platforms) speaks a JSON-lines protocol with token auth. Reads/writes of terminal surfaces (`get-text`/`send-text`) go through the existing process-global `surface_registry` liveness guard (mutex-based, cross-platform) — **no UI-thread marshaling**, mirroring the agent worker host (`agentSurfaceSnapshot`/`agentWriteSurface`). Only `panes` needs threadlocal tab topology, which the UI thread publishes into a mutex-guarded JSON buffer on the render tick (alongside `syncRemoteLayout`). `wait-for` is pure client-side polling of `get-text`. The client `wisptermctl` is a separate lean exe that auto-discovers the running instance via a `0600` `{port, token}` file in the config dir.

> **Why not the weixin `SendMessage` marshaling pattern (as the issue's analysis suggested)?** On **Linux** `window_backend.sendMessage`/`postMessage` are **no-ops** (`window_linux.zig:67-81` — SDL has no Win32 message bus). macOS emulates it, Windows is native, but Linux is not. The cross-platform goal therefore rules out SendMessage for the data path. `surface_registry` (`acquire`/`release`, doc explicitly blesses "snapshot serialization, queueing PTY input") is genuinely cross-platform and already proven by the agent worker.

**Tech Stack:** Zig 0.15.2, `std.net` (loopback TCP), `std.json` (protocol codec), existing `surface_registry.zig`, `remote_snapshot.allocTerminalSnapshot`, `Surface.queuePtyWrite`, `platform/dirs.zig` (config dir).

---

## File Structure

**New (pure, standalone — importable by both app and the lean client):**
- `src/ctl/protocol.zig` — JSON-lines request/response codec. std-only.
- `src/ctl/discovery.zig` — `{port, token}` file: path (config dir), encode/parse, write `0600`, read, remove. Imports only `platform/dirs.zig` (std+builtin).
- `src/ctl/control.zig` — `Control` vtable abstraction (list_panes / get_text / send_text). The real impl lives in AppWindow; tests use a fake. Mirrors `weixin/control.zig`.
- `src/ctl/server.zig` — localhost TCP listener + accept thread + per-connection request dispatch through a `Control`. Platform-neutral (no GUI deps), mirrors `weixin/controller.zig` lifecycle.
- `src/ctl/client.zig` — pure client helpers: arg parsing, escape decoding, wait-for substring match, request/response over a `std.net.Stream`. std-only.
- `src/wisptermctl.zig` — the client exe `main()`: parse argv → discover → connect → dispatch → print; `wait-for` polling loop.

**Modified (integration, shared files — sequential):**
- `src/surface_registry.zig` — add `acquireById(id) ?*anyopaque`.
- `src/AppWindow.zig` — ctl `Control` impl (`ctlGetText`/`ctlSendText` via registry; `ctlListPanes` reads published JSON), `buildCtlPanesJson`, `syncCtlPanes` (UI publish), `enableAgentControl`, `agentControl()`; call `syncCtlPanes(allocator)` next to `syncRemoteLayout` (line ~6889).
- `src/App.zig` — `agent_control_server: ?*ctl_server.Server` field; `startAgentControl(cfg)`; shutdown in `deinit`.
- `src/main.zig` — `app.startAgentControl(&cfg);` after `startWeixin`.
- `src/config.zig` — `agent-control-enabled: bool = false`, `agent-control-port: u16 = 0`; applyKeyValue branches; usage + sample config.
- `build.zig` — `wisptermctl` exe target; register `ctl/*` pure tests into fast suite + a posix round-trip test.
- `src/test_fast.zig` — `_ = @import("ctl/protocol.zig"); _ = @import("ctl/discovery.zig"); _ = @import("ctl/client.zig");`
- `src/test_main.zig` — `_ = @import("ctl/control.zig");` (+ AppWindow ctl-callback test lives in AppWindow.zig, already imported).
- `src/test_posix.zig` — server loopback round-trip test.
- `docs/ai-agent.md` (or a new `docs/agent-control.md`) — user docs (P2-adjacent; include a short section).

---

## Protocol (JSON-lines, one object per line, `\n`-terminated)

Request (client → server):
```json
{"token":"<hex>","cmd":"panes"}
{"token":"<hex>","cmd":"get-text","id":"<surface-id>","recent":200}
{"token":"<hex>","cmd":"send-text","id":"<surface-id>","data":"ls\n"}
```
Response (server → client):
```json
{"ok":true,"result":<panes-json-object>}     // panes
{"ok":true,"result":"<terminal text>"}        // get-text (JSON string)
{"ok":true}                                   // send-text
{"ok":false,"error":"unauthorized"}           // auth fail / bad id / malformed
```
- `result` is a raw JSON value: an object for `panes`, a JSON string for `get-text`, absent for `send-text`.
- `data` (send-text) is already-decoded raw bytes carried as a JSON string (the client decodes `\n`/`\t`/`\r`/`\\`/`\xNN` escapes before encoding).
- `recent` (get-text) optional; server caps it at `remote_snapshot.default_max_history_rows`. Default when absent: `ctl_default_rows` (1000).

---

## Task 1: `surface_registry.acquireById`

**Files:**
- Modify: `src/surface_registry.zig`

- [ ] **Step 1: Write the failing tests** (append to the test block)

```zig
test "acquireById returns the live pointer for a registered id (lock held until release)" {
    register(&test_target_a, "find-me");
    defer unregister(&test_target_a);

    const got = acquireById("find-me");
    try std.testing.expect(got != null);
    try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&test_target_a)), got.?);
    release();
}

test "acquireById returns null for an unknown id (no lock held)" {
    try std.testing.expect(acquireById("nope") == null);
    // If the lock were still held this would deadlock; it must not.
    register(&test_target_b, "present");
    defer unregister(&test_target_b);
    try std.testing.expect(acquireById("present") != null);
    release();
}

test "acquireById holds the lock so unregister blocks until release" {
    register(&test_target_a, "guarded");
    try std.testing.expect(acquireById("guarded") != null);

    var done = std.atomic.Value(bool).init(false);
    const Closure = struct {
        fn run(flag: *std.atomic.Value(bool)) void {
            unregister(&test_target_a);
            flag.store(true, .release);
        }
    };
    const th = try std.Thread.spawn(.{}, Closure.run, .{&done});
    std.Thread.sleep(50 * std.time.ns_per_ms);
    try std.testing.expect(!done.load(.acquire));
    release();
    th.join();
    try std.testing.expect(done.load(.acquire));
}
```

- [ ] **Step 2: Run, verify fail** — `zig build test` → FAIL (`acquireById` undefined).

- [ ] **Step 3: Implement** (add after `acquire`/`release`)

```zig
/// If a live surface is registered under `id`, returns its pointer with the
/// registry lock HELD — the caller MUST call release() when done. Returns null
/// (lock not held) when no live surface matches. The ctl server uses this to
/// pin a surface by id from its background thread, exactly as the agent worker
/// uses acquire() with a pre-captured pointer.
pub fn acquireById(id: []const u8) ?*anyopaque {
    g_mutex.lock();
    for (g_entries) |entry| {
        if (entry) |live| {
            if (std.mem.eql(u8, live.idSlice(), id)) return live.ptr;
        }
    }
    g_mutex.unlock();
    return null;
}
```

- [ ] **Step 4: Run, verify pass** — `zig build test` → PASS.
- [ ] **Step 5: Commit** — `feat(ctl): add surface_registry.acquireById for id-keyed pinning`

---

## Task 2: `ctl/protocol.zig` (request/response codec)

**Files:**
- Create: `src/ctl/protocol.zig`
- Modify: `src/test_fast.zig` (add import)

- [ ] **Step 1: Write the module with tests** (TDD: tests at bottom).

```zig
//! JSON-lines wire protocol for the agent terminal control API (wisptermctl).
//! Pure: std-only, no GUI/socket deps, so both the in-process server and the
//! standalone client compile against it. One JSON object per line, '\n'-terminated.
const std = @import("std");

pub const Cmd = enum { panes, get_text, send_text };

pub fn cmdToStr(c: Cmd) []const u8 {
    return switch (c) {
        .panes => "panes",
        .get_text => "get-text",
        .send_text => "send-text",
    };
}

pub fn cmdFromStr(s: []const u8) ?Cmd {
    if (std.mem.eql(u8, s, "panes")) return .panes;
    if (std.mem.eql(u8, s, "get-text")) return .get_text;
    if (std.mem.eql(u8, s, "send-text")) return .send_text;
    return null;
}

pub const Request = struct {
    token: []const u8 = "",
    cmd: Cmd,
    id: []const u8 = "",
    recent: ?u32 = null,
    data: []const u8 = "",
};

/// Build one newline-terminated JSON request line. Caller owns the result.
pub fn encodeRequest(allocator: std.mem.Allocator, req: Request) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"token\":");
    try writeJsonString(allocator, &out, req.token);
    try out.appendSlice(allocator, ",\"cmd\":");
    try writeJsonString(allocator, &out, cmdToStr(req.cmd));
    if (req.id.len != 0) {
        try out.appendSlice(allocator, ",\"id\":");
        try writeJsonString(allocator, &out, req.id);
    }
    if (req.recent) |n| {
        try out.appendSlice(allocator, ",\"recent\":");
        try out.print(allocator, "{d}", .{n});
    }
    if (req.cmd == .send_text) {
        try out.appendSlice(allocator, ",\"data\":");
        try writeJsonString(allocator, &out, req.data);
    }
    try out.appendSlice(allocator, "}\n");
    return out.toOwnedSlice(allocator);
}

/// Parsed request; owns an arena that backs the borrowed slices.
pub const ParsedRequest = struct {
    arena: std.heap.ArenaAllocator,
    value: Request,
    pub fn deinit(self: *ParsedRequest) void {
        self.arena.deinit();
    }
};

/// Parse one request line. Errors on malformed JSON or unknown/absent cmd.
pub fn parseRequest(allocator: std.mem.Allocator, line: []const u8) !ParsedRequest {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    // alloc_always: keep strings independent of `line` (caller may reuse the buffer).
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, line, .{ .allocate = .alloc_always });
    if (parsed != .object) return error.InvalidRequest;
    const obj = parsed.object;

    const cmd_str = stringField(obj, "cmd") orelse return error.InvalidRequest;
    const cmd = cmdFromStr(cmd_str) orelse return error.UnknownCommand;
    var req = Request{ .cmd = cmd };
    req.token = stringField(obj, "token") orelse "";
    req.id = stringField(obj, "id") orelse "";
    req.data = stringField(obj, "data") orelse "";
    if (obj.get("recent")) |v| {
        if (v == .integer and v.integer >= 0) req.recent = @intCast(v.integer);
    }
    return .{ .arena = arena, .value = req };
}

fn stringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

// --- server response builders (newline-terminated; caller owns) ---

pub fn encodeOk(allocator: std.mem.Allocator) ![]u8 {
    return allocator.dupe(u8, "{\"ok\":true}\n");
}

pub fn encodeOkText(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"ok\":true,\"result\":");
    try writeJsonString(allocator, &out, text);
    try out.appendSlice(allocator, "}\n");
    return out.toOwnedSlice(allocator);
}

/// `raw` must already be valid JSON (e.g. the panes object). Embedded verbatim.
pub fn encodeOkRawJson(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"ok\":true,\"result\":");
    try out.appendSlice(allocator, raw);
    try out.appendSlice(allocator, "}\n");
    return out.toOwnedSlice(allocator);
}

pub fn encodeError(allocator: std.mem.Allocator, msg: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"ok\":false,\"error\":");
    try writeJsonString(allocator, &out, msg);
    try out.appendSlice(allocator, "}\n");
    return out.toOwnedSlice(allocator);
}

// --- client response parsing ---

pub const Response = struct {
    arena: std.heap.ArenaAllocator,
    ok: bool,
    error_msg: []const u8 = "", // borrows arena
    /// result decoded as a JSON string (get-text), else null.
    result_text: ?[]const u8 = null, // borrows arena
    /// raw JSON text of `result` (panes object), or "" when absent.
    result_raw: []const u8 = "", // borrows arena
    pub fn deinit(self: *Response) void {
        self.arena.deinit();
    }
};

pub fn parseResponse(allocator: std.mem.Allocator, line: []const u8) !Response {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, line, .{ .allocate = .alloc_always });
    if (parsed != .object) return error.InvalidResponse;
    const obj = parsed.object;
    const ok = if (obj.get("ok")) |v| (v == .bool and v.bool) else false;
    var resp = Response{ .arena = arena, .ok = ok };
    resp.error_msg = stringField(obj, "error") orelse "";
    if (obj.get("result")) |v| {
        if (v == .string) {
            resp.result_text = v.string;
        } else {
            // Re-stringify non-string results (panes object) for passthrough.
            resp.result_raw = try std.json.Stringify.valueAlloc(a, v, .{});
        }
    }
    return resp;
}

// helper: minimal JSON string writer (std.json.Stringify-compatible escaping)
fn writeJsonString(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
    const encoded = try std.json.Stringify.valueAlloc(allocator, std.json.Value{ .string = s }, .{});
    defer allocator.free(encoded);
    try out.appendSlice(allocator, encoded);
}

// ---- tests ----
const t = std.testing;

test "request round-trips token/cmd/id/recent" {
    const line = try encodeRequest(t.allocator, .{ .token = "abc", .cmd = .get_text, .id = "surf01", .recent = 50 });
    defer t.allocator.free(line);
    try t.expect(line[line.len - 1] == '\n');
    var pr = try parseRequest(t.allocator, line);
    defer pr.deinit();
    try t.expectEqualStrings("abc", pr.value.token);
    try t.expectEqual(Cmd.get_text, pr.value.cmd);
    try t.expectEqualStrings("surf01", pr.value.id);
    try t.expectEqual(@as(?u32, 50), pr.value.recent);
}

test "send-text data with newline survives JSON round-trip" {
    const line = try encodeRequest(t.allocator, .{ .token = "x", .cmd = .send_text, .id = "s", .data = "ls -la\n" });
    defer t.allocator.free(line);
    var pr = try parseRequest(t.allocator, line);
    defer pr.deinit();
    try t.expectEqualStrings("ls -la\n", pr.value.data);
}

test "parseRequest rejects unknown command and non-object" {
    try t.expectError(error.UnknownCommand, parseRequest(t.allocator, "{\"cmd\":\"nope\"}"));
    try t.expectError(error.InvalidRequest, parseRequest(t.allocator, "[]"));
    try t.expectError(error.InvalidRequest, parseRequest(t.allocator, "{\"token\":\"x\"}"));
}

test "ok-text response round-trips terminal text with control chars" {
    const line = try encodeOkText(t.allocator, "line1\r\n\"quoted\"\t\x1b[0m");
    defer t.allocator.free(line);
    var r = try parseResponse(t.allocator, line);
    defer r.deinit();
    try t.expect(r.ok);
    try t.expectEqualStrings("line1\r\n\"quoted\"\t\x1b[0m", r.result_text.?);
}

test "ok-raw-json response exposes result_raw, error response carries message" {
    const ok = try encodeOkRawJson(t.allocator, "{\"activeTab\":0,\"tabs\":[]}");
    defer t.allocator.free(ok);
    var r = try parseResponse(t.allocator, ok);
    defer r.deinit();
    try t.expect(r.ok);
    try t.expect(r.result_raw.len > 0);
    try t.expect(std.mem.indexOf(u8, r.result_raw, "activeTab") != null);

    const err = try encodeError(t.allocator, "unauthorized");
    defer t.allocator.free(err);
    var re = try parseResponse(t.allocator, err);
    defer re.deinit();
    try t.expect(!re.ok);
    try t.expectEqualStrings("unauthorized", re.error_msg);
}
```

> NOTE: verify the exact 0.15.2 std.json stringify entry point during impl (`std.json.Stringify.valueAlloc` vs `std.json.stringifyAlloc`). Adjust `writeJsonString`/`parseResponse` to whichever the stdlib exposes; keep the escaping behavior.

- [ ] **Step 2: Add import to `src/test_fast.zig`** — `_ = @import("ctl/protocol.zig");`
- [ ] **Step 3: Run, verify pass** — `zig build test` → PASS.
- [ ] **Step 4: Commit** — `feat(ctl): JSON-lines protocol codec`

---

## Task 3: `ctl/discovery.zig` ({port, token} file)

**Files:**
- Create: `src/ctl/discovery.zig`
- Modify: `src/test_fast.zig` (add import)

- [ ] **Step 1: Write the module with tests.**

```zig
//! Auto-discovery file for wisptermctl: a 0600 JSON file in the config dir
//! holding the running instance's loopback port + auth token. The server writes
//! it on start and removes it on shutdown; the client reads it to connect.
const std = @import("std");
const platform_dirs = @import("../platform/dirs.zig");

pub const basename = "agent-control.json";

pub const Info = struct {
    port: u16,
    token: []const u8, // owned by the caller's allocator after read()
};

pub fn filePath(allocator: std.mem.Allocator) ![]const u8 {
    return platform_dirs.pathInConfigDir(allocator, basename);
}

/// Serialize to JSON (no trailing newline). Caller owns.
pub fn encode(allocator: std.mem.Allocator, info: Info) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.print(allocator, "{{\"port\":{d},\"token\":", .{info.port});
    const tok = try std.json.Stringify.valueAlloc(allocator, std.json.Value{ .string = info.token }, .{});
    defer allocator.free(tok);
    try out.appendSlice(allocator, tok);
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

/// Parse file content. `token` is duped into `allocator` (caller frees).
pub fn parse(allocator: std.mem.Allocator, content: []const u8) !Info {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), content, .{ .allocate = .alloc_always });
    if (parsed != .object) return error.InvalidDiscovery;
    const obj = parsed.object;
    const port_v = obj.get("port") orelse return error.InvalidDiscovery;
    const tok_v = obj.get("token") orelse return error.InvalidDiscovery;
    if (port_v != .integer or tok_v != .string) return error.InvalidDiscovery;
    if (port_v.integer <= 0 or port_v.integer > 65535) return error.InvalidDiscovery;
    return .{ .port = @intCast(port_v.integer), .token = try allocator.dupe(u8, tok_v.string) };
}

/// Write the discovery file with owner-only (0600) perms. Replaces any existing.
pub fn write(allocator: std.mem.Allocator, info: Info) !void {
    const path = try filePath(allocator);
    defer allocator.free(path);
    const body = try encode(allocator, info);
    defer allocator.free(body);
    // Recreate so perms tighten even if a looser file existed.
    std.fs.cwd().deleteFile(path) catch {};
    var file = try std.fs.cwd().createFile(path, .{ .mode = 0o600 });
    defer file.close();
    try file.writeAll(body);
}

/// Read + parse. Returns null when the file is absent. Token owned by caller.
pub fn read(allocator: std.mem.Allocator) !?Info {
    const path = try filePath(allocator);
    defer allocator.free(path);
    const content = std.fs.cwd().readFileAlloc(allocator, path, 64 * 1024) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(content);
    return try parse(allocator, content);
}

pub fn remove(allocator: std.mem.Allocator) void {
    const path = filePath(allocator) catch return;
    defer allocator.free(path);
    std.fs.cwd().deleteFile(path) catch {};
}

// ---- tests ----
const t = std.testing;

test "encode/parse round-trip" {
    const body = try encode(t.allocator, .{ .port = 51234, .token = "deadbeef" });
    defer t.allocator.free(body);
    const info = try parse(t.allocator, body);
    defer t.allocator.free(info.token);
    try t.expectEqual(@as(u16, 51234), info.port);
    try t.expectEqualStrings("deadbeef", info.token);
}

test "parse rejects malformed / out-of-range" {
    try t.expectError(error.InvalidDiscovery, parse(t.allocator, "{}"));
    try t.expectError(error.InvalidDiscovery, parse(t.allocator, "{\"port\":0,\"token\":\"x\"}"));
    try t.expectError(error.InvalidDiscovery, parse(t.allocator, "{\"port\":70000,\"token\":\"x\"}"));
}

test "write then read round-trips via a redirected config dir" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(t.allocator, ".");
    defer t.allocator.free(dir_path);
    platform_dirs.setTestConfigDirForCurrentThread(dir_path);
    defer platform_dirs.clearTestConfigDirForCurrentThread();

    try write(t.allocator, .{ .port = 40000, .token = "tok123" });
    const got = (try read(t.allocator)).?;
    defer t.allocator.free(got.token);
    try t.expectEqual(@as(u16, 40000), got.port);
    try t.expectEqualStrings("tok123", got.token);

    remove(t.allocator);
    try t.expect((try read(t.allocator)) == null);
}
```

> NOTE: confirm `setTestConfigDirForCurrentThread` makes `pathInConfigDir` resolve under the temp dir (it is the documented seam at dirs.zig:20). Confirm 0.15.2 `readFileAlloc` arg order (`(allocator, path, max)` vs `(path, allocator, max)`); adjust if needed.

- [ ] **Step 2: Add import to `src/test_fast.zig`** — `_ = @import("ctl/discovery.zig");`
- [ ] **Step 3: Run, verify pass** — `zig build test` → PASS.
- [ ] **Step 4: Commit** — `feat(ctl): discovery file (port+token, 0600)`

---

## Task 4: `ctl/control.zig` (Control vtable)

**Files:**
- Create: `src/ctl/control.zig`
- Modify: `src/test_main.zig` (add import)

- [ ] **Step 1: Write with a fake-backed test.**

```zig
//! Boundary between the ctl server thread and the live WispTerm surfaces.
//! The real vtable is supplied by AppWindow (cross-platform: get_text/send_text
//! go through surface_registry; list_panes reads a UI-published JSON buffer).
//! Tests supply a fake. Mirrors weixin/control.zig.
const std = @import("std");

pub const Control = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Allocator-owned panes JSON object, or null if not yet published.
        list_panes: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) anyerror!?[]u8,
        /// Allocator-owned snapshot text for `id`, or null if no live surface.
        get_text: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, id: []const u8, recent: ?u32) anyerror!?[]u8,
        /// Queue raw bytes to surface `id`. Returns false if no live surface.
        send_text: *const fn (ctx: *anyopaque, id: []const u8, data: []const u8) bool,
    };

    pub fn listPanes(self: Control, allocator: std.mem.Allocator) anyerror!?[]u8 {
        return self.vtable.list_panes(self.ctx, allocator);
    }
    pub fn getText(self: Control, allocator: std.mem.Allocator, id: []const u8, recent: ?u32) anyerror!?[]u8 {
        return self.vtable.get_text(self.ctx, allocator, id, recent);
    }
    pub fn sendText(self: Control, id: []const u8, data: []const u8) bool {
        return self.vtable.send_text(self.ctx, id, data);
    }
};

const t = std.testing;

test "Control forwards to the vtable" {
    const Fake = struct {
        fn list_panes(_: *anyopaque, a: std.mem.Allocator) anyerror!?[]u8 {
            return try a.dupe(u8, "{\"tabs\":[]}");
        }
        fn get_text(_: *anyopaque, a: std.mem.Allocator, id: []const u8, _: ?u32) anyerror!?[]u8 {
            if (std.mem.eql(u8, id, "live")) return try a.dupe(u8, "hello");
            return null;
        }
        fn send_text(_: *anyopaque, id: []const u8, _: []const u8) bool {
            return std.mem.eql(u8, id, "live");
        }
        var dummy: u8 = 0;
        fn iface() Control {
            return .{ .ctx = &dummy, .vtable = &.{ .list_panes = list_panes, .get_text = get_text, .send_text = send_text } };
        }
    };
    const c = Fake.iface();
    const panes = (try c.listPanes(t.allocator)).?;
    defer t.allocator.free(panes);
    try t.expectEqualStrings("{\"tabs\":[]}", panes);
    const text = (try c.getText(t.allocator, "live", null)).?;
    defer t.allocator.free(text);
    try t.expectEqualStrings("hello", text);
    try t.expect((try c.getText(t.allocator, "gone", null)) == null);
    try t.expect(c.sendText("live", "x"));
    try t.expect(!c.sendText("gone", "x"));
}
```

- [ ] **Step 2: Add import to `src/test_main.zig`** — `_ = @import("ctl/control.zig");`
- [ ] **Step 3: Run, verify pass** — `zig build test-full` → PASS (control test is in the app suite; it is std-only so it can also go in test_fast — put it in test_fast for speed: `_ = @import("ctl/control.zig");`).
- [ ] **Step 4: Commit** — `feat(ctl): Control vtable boundary`

---

## Task 5: `ctl/server.zig` (listener + dispatch)

**Files:**
- Create: `src/ctl/server.zig`
- Modify: `src/test_posix.zig` (loopback round-trip test)

- [ ] **Step 1: Write the server.**

```zig
//! In-process localhost TCP control server for wisptermctl. Platform-neutral
//! (no GUI deps): binds 127.0.0.1, accepts one JSON-lines request per
//! connection, authenticates the token, dispatches through a Control, replies,
//! and closes. Reads/writes of surfaces are cross-platform (the Control impl
//! uses surface_registry, not Win32 SendMessage). Lifecycle mirrors
//! weixin/controller.zig: created by App with a live Control.
const std = @import("std");
const protocol = @import("protocol.zig");
const control_mod = @import("control.zig");

const MAX_REQUEST_BYTES = 64 * 1024;
pub const default_rows: u32 = 1000;

pub const Server = struct {
    allocator: std.mem.Allocator,
    control: control_mod.Control,
    token: []u8, // owned
    listener: std.net.Server,
    port: u16,
    thread: ?std.Thread = null,
    stop_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Binds 127.0.0.1:`port` (0 = OS-assigned). Dupes `token`. Caller owns.
    pub fn create(allocator: std.mem.Allocator, control: control_mod.Control, token: []const u8, port: u16) !*Server {
        const address = try std.net.Address.parseIp4("127.0.0.1", port);
        var listener = try address.listen(.{ .reuse_address = true });
        errdefer listener.deinit();
        const self = try allocator.create(Server);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .control = control,
            .token = try allocator.dupe(u8, token),
            .listener = listener,
            .port = listener.listen_address.getPort(),
        };
        return self;
    }

    pub fn start(self: *Server) !void {
        self.thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
    }

    pub fn stop(self: *Server) void {
        if (self.thread == null) return;
        self.stop_flag.store(true, .release);
        // Unblock accept() with a throwaway connection to our own port.
        const addr = std.net.Address.parseIp4("127.0.0.1", self.port) catch return;
        if (std.net.tcpConnectToAddress(addr)) |s| s.close() else |_| {}
        self.thread.?.join();
        self.thread = null;
    }

    pub fn destroy(self: *Server) void {
        self.stop();
        self.listener.deinit();
        self.allocator.free(self.token);
        self.allocator.destroy(self);
    }

    fn acceptLoop(self: *Server) void {
        while (!self.stop_flag.load(.acquire)) {
            const conn = self.listener.accept() catch continue;
            defer conn.stream.close();
            if (self.stop_flag.load(.acquire)) return;
            self.handleConnection(conn.stream) catch {};
        }
    }

    fn handleConnection(self: *Server, stream: std.net.Stream) !void {
        // Read one line (up to MAX_REQUEST_BYTES).
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(self.allocator);
        var chunk: [4096]u8 = undefined;
        while (buf.items.len < MAX_REQUEST_BYTES) {
            const n = stream.read(&chunk) catch break;
            if (n == 0) break;
            try buf.appendSlice(self.allocator, chunk[0..n]);
            if (std.mem.indexOfScalar(u8, buf.items, '\n') != null) break;
        }
        const line = blk: {
            const nl = std.mem.indexOfScalar(u8, buf.items, '\n') orelse buf.items.len;
            break :blk buf.items[0..nl];
        };
        const reply = try self.dispatch(line);
        defer self.allocator.free(reply);
        stream.writeAll(reply) catch {};
    }

    /// Pure-ish dispatch (modulo Control side effects). Returns an owned reply line.
    fn dispatch(self: *Server, line: []const u8) ![]u8 {
        var parsed = protocol.parseRequest(self.allocator, line) catch
            return protocol.encodeError(self.allocator, "invalid request");
        defer parsed.deinit();
        const req = parsed.value;

        if (!tokenEqual(self.token, req.token))
            return protocol.encodeError(self.allocator, "unauthorized");

        switch (req.cmd) {
            .panes => {
                const json = (try self.control.listPanes(self.allocator)) orelse
                    return protocol.encodeError(self.allocator, "panes not available");
                defer self.allocator.free(json);
                return protocol.encodeOkRawJson(self.allocator, json);
            },
            .get_text => {
                if (req.id.len == 0) return protocol.encodeError(self.allocator, "missing id");
                const text = (try self.control.getText(self.allocator, req.id, req.recent)) orelse
                    return protocol.encodeError(self.allocator, "surface not found");
                defer self.allocator.free(text);
                return protocol.encodeOkText(self.allocator, text);
            },
            .send_text => {
                if (req.id.len == 0) return protocol.encodeError(self.allocator, "missing id");
                if (!self.control.sendText(req.id, req.data))
                    return protocol.encodeError(self.allocator, "surface not found");
                return protocol.encodeOk(self.allocator);
            },
        }
    }
};

/// Constant-time token comparison.
fn tokenEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len or a.len == 0) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| diff |= x ^ y;
    return diff == 0;
}

// ---- tests (pure dispatch; no sockets) ----
const t = std.testing;

const FakeControl = struct {
    sent: std.ArrayListUnmanaged(u8) = .empty,
    fn list_panes(ctx: *anyopaque, a: std.mem.Allocator) anyerror!?[]u8 {
        _ = ctx;
        return try a.dupe(u8, "{\"tabs\":[]}");
    }
    fn get_text(ctx: *anyopaque, a: std.mem.Allocator, id: []const u8, _: ?u32) anyerror!?[]u8 {
        _ = ctx;
        if (std.mem.eql(u8, id, "s1")) return try a.dupe(u8, "screen");
        return null;
    }
    fn send_text(ctx: *anyopaque, id: []const u8, data: []const u8) bool {
        const self: *FakeControl = @ptrCast(@alignCast(ctx));
        if (!std.mem.eql(u8, id, "s1")) return false;
        self.sent.appendSlice(t.allocator, data) catch return false;
        return true;
    }
    fn iface(self: *FakeControl) control_mod.Control {
        return .{ .ctx = self, .vtable = &.{ .list_panes = list_panes, .get_text = get_text, .send_text = send_text } };
    }
};

fn fakeServer(fc: *FakeControl) Server {
    return .{ .allocator = t.allocator, .control = fc.iface(), .token = @constCast("secret"), .listener = undefined, .port = 0 };
}

test "dispatch rejects bad token" {
    var fc = FakeControl{};
    defer fc.sent.deinit(t.allocator);
    var srv = fakeServer(&fc);
    const line = try protocol.encodeRequest(t.allocator, .{ .token = "wrong", .cmd = .panes });
    defer t.allocator.free(line);
    const reply = try srv.dispatch(line);
    defer t.allocator.free(reply);
    try t.expect(std.mem.indexOf(u8, reply, "unauthorized") != null);
}

test "dispatch panes / get-text / send-text happy paths" {
    var fc = FakeControl{};
    defer fc.sent.deinit(t.allocator);
    var srv = fakeServer(&fc);

    const p = try protocol.encodeRequest(t.allocator, .{ .token = "secret", .cmd = .panes });
    defer t.allocator.free(p);
    const pr = try srv.dispatch(p);
    defer t.allocator.free(pr);
    try t.expect(std.mem.indexOf(u8, pr, "\"ok\":true") != null);

    const g = try protocol.encodeRequest(t.allocator, .{ .token = "secret", .cmd = .get_text, .id = "s1" });
    defer t.allocator.free(g);
    const gr = try srv.dispatch(g);
    defer t.allocator.free(gr);
    try t.expect(std.mem.indexOf(u8, gr, "screen") != null);

    const gmiss = try protocol.encodeRequest(t.allocator, .{ .token = "secret", .cmd = .get_text, .id = "ghost" });
    defer t.allocator.free(gmiss);
    const gmr = try srv.dispatch(gmiss);
    defer t.allocator.free(gmr);
    try t.expect(std.mem.indexOf(u8, gmr, "surface not found") != null);

    const s = try protocol.encodeRequest(t.allocator, .{ .token = "secret", .cmd = .send_text, .id = "s1", .data = "echo hi\n" });
    defer t.allocator.free(s);
    const sr = try srv.dispatch(s);
    defer t.allocator.free(sr);
    try t.expect(std.mem.indexOf(u8, sr, "\"ok\":true") != null);
    try t.expectEqualStrings("echo hi\n", fc.sent.items);
}
```

> The dispatch tests are pure (no socket) and can live in `test_fast` via `_ = @import("ctl/server.zig");`. Add a **real loopback round-trip** test in `test_posix.zig` (Step 2).

- [ ] **Step 2: Loopback round-trip test in `src/test_posix.zig`**

```zig
test "ctl server answers a real loopback request" {
    const ctl_server = @import("ctl/server.zig");
    const protocol = @import("ctl/protocol.zig");
    const control_mod = @import("ctl/control.zig");

    const C = struct {
        fn list_panes(_: *anyopaque, a: std.mem.Allocator) anyerror!?[]u8 {
            return try a.dupe(u8, "{\"tabs\":[]}");
        }
        fn get_text(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: ?u32) anyerror!?[]u8 {
            return null;
        }
        fn send_text(_: *anyopaque, _: []const u8, _: []const u8) bool {
            return false;
        }
        var dummy: u8 = 0;
        fn iface() control_mod.Control {
            return .{ .ctx = &dummy, .vtable = &.{ .list_panes = list_panes, .get_text = get_text, .send_text = send_text } };
        }
    };

    const srv = try ctl_server.Server.create(std.testing.allocator, C.iface(), "tok", 0);
    defer srv.destroy();
    try srv.start();

    const addr = try std.net.Address.parseIp4("127.0.0.1", srv.port);
    var stream = try std.net.tcpConnectToAddress(addr);
    defer stream.close();
    const line = try protocol.encodeRequest(std.testing.allocator, .{ .token = "tok", .cmd = .panes });
    defer std.testing.allocator.free(line);
    try stream.writeAll(line);

    var buf: [4096]u8 = undefined;
    const n = try stream.read(&buf);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "\"ok\":true") != null);
}
```

- [ ] **Step 3: Add `_ = @import("ctl/server.zig");` to `src/test_fast.zig`** (for the pure dispatch tests).
- [ ] **Step 4: Run** — `zig build test` (fast + dispatch) and `zig build test-full` (posix round-trip) → PASS.
- [ ] **Step 5: Commit** — `feat(ctl): localhost TCP server + token-auth dispatch`

---

## Task 6: AppWindow ctl Control implementation + panes publish

**Files:**
- Modify: `src/AppWindow.zig`

Add near the other imports: `const ctl_control = @import("ctl/control.zig");` (and `ctl_server` is referenced from App.zig, not here).

- [ ] **Step 1: Globals + cross-platform get/send/list + publish (place after the weixin Control block ~line 4955).**

```zig
// ============================================================================
// Agent terminal control (wisptermctl) — cross-platform Control surface.
//
// Unlike the weixin path, this does NOT marshal to the UI thread: Win32
// SendMessage is a no-op on Linux. get-text/send-text pin the target surface
// through surface_registry (mutex liveness guard) and run on the ctl server
// thread, exactly like the agent worker host (agentSurfaceSnapshot/Write).
// Only `panes` needs threadlocal tab topology, so the UI thread publishes a
// JSON snapshot into g_ctl_panes_json on the render tick (syncCtlPanes).
// ============================================================================

var g_agent_control_enabled = std.atomic.Value(bool).init(false);
var g_ctl_ctx: u8 = 0;
var g_ctl_panes_mutex: std.Thread.Mutex = .{};
var g_ctl_panes_json: []u8 = &.{}; // page_allocator-owned latest panes JSON
var g_ctl_panes_last_ms: i64 = 0;

const ctl_default_rows: u32 = 1000;

pub fn enableAgentControl() void {
    g_agent_control_enabled.store(true, .release);
}

fn ctlListPanes(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror!?[]u8 {
    _ = ctx;
    g_ctl_panes_mutex.lock();
    defer g_ctl_panes_mutex.unlock();
    if (g_ctl_panes_json.len == 0) return null;
    return try allocator.dupe(u8, g_ctl_panes_json);
}

fn ctlGetText(ctx: *anyopaque, allocator: std.mem.Allocator, id: []const u8, recent: ?u32) anyerror!?[]u8 {
    _ = ctx;
    const ptr = surface_registry.acquireById(id) orelse return null;
    defer surface_registry.release();
    const surface: *Surface = @ptrCast(@alignCast(ptr));
    const want: usize = if (recent) |r| r else ctl_default_rows;
    const rows = @min(want, remote_snapshot.default_max_history_rows);
    return try buildRemoteSurfaceSnapshot(allocator, surface, rows);
}

fn ctlSendText(ctx: *anyopaque, id: []const u8, data: []const u8) bool {
    _ = ctx;
    const ptr = surface_registry.acquireById(id) orelse return false;
    defer surface_registry.release();
    const surface: *Surface = @ptrCast(@alignCast(ptr));
    surface.queuePtyWrite(data);
    return true;
}

const ctl_vtable = ctl_control.Control.VTable{
    .list_panes = ctlListPanes,
    .get_text = ctlGetText,
    .send_text = ctlSendText,
};

pub fn agentControl() ctl_control.Control {
    return .{ .ctx = &g_ctl_ctx, .vtable = &ctl_vtable };
}

/// UI-thread: publish a fresh panes JSON snapshot (throttled). Called from the
/// render loop next to syncRemoteLayout. No-op unless ctl is enabled.
fn syncCtlPanes(allocator: std.mem.Allocator) void {
    if (!g_agent_control_enabled.load(.acquire)) return;
    const now = std.time.milliTimestamp();
    if (now - g_ctl_panes_last_ms < 200) return;
    g_ctl_panes_last_ms = now;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    buildCtlPanesJson(allocator, &out) catch return;

    const owned = std.heap.page_allocator.dupe(u8, out.items) catch return;
    g_ctl_panes_mutex.lock();
    defer g_ctl_panes_mutex.unlock();
    if (g_ctl_panes_json.len != 0) std.heap.page_allocator.free(g_ctl_panes_json);
    g_ctl_panes_json = owned;
}
```

- [ ] **Step 2: `buildCtlPanesJson` — mirror `buildRemoteLayoutJson` minus snapshots, plus cwd.** Place right after `buildRemoteLayoutJson` (~line 4504). Emit per-terminal-surface: id, title, focused, cols, rows, cursorX/Y, cwd, agentApp/agentState, geometry. For ai_chat/ai_history tabs emit `{index,title,kind,"surfaces":[]}`.

```zig
fn buildCtlPanesJson(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
    try out.appendSlice(allocator, "{\"activeTab\":");
    try out.print(allocator, "{d}", .{active_tab_state.g_active_tab});
    try out.appendSlice(allocator, ",\"tabs\":[");
    var wrote_tab = false;
    for (0..tab.g_tab_count) |tab_index| {
        const tab_state = tab.g_tabs[tab_index] orelse continue;
        if (wrote_tab) try out.append(allocator, ',');
        wrote_tab = true;

        if (tab_state.kind != .terminal) {
            try out.appendSlice(allocator, "{\"index\":");
            try out.print(allocator, "{d}", .{tab_index});
            try out.appendSlice(allocator, ",\"title\":\"");
            try remote.appendJsonString(out, allocator, tab_state.getTitle());
            try out.appendSlice(allocator, "\",\"kind\":\"");
            try remote.appendJsonString(out, allocator, @tagName(tab_state.kind));
            try out.appendSlice(allocator, "\",\"surfaces\":[]}");
            continue;
        }

        try out.appendSlice(allocator, "{\"index\":");
        try out.print(allocator, "{d}", .{tab_index});
        try out.appendSlice(allocator, ",\"title\":\"");
        try remote.appendJsonString(out, allocator, tab_state.getTitle());
        try out.appendSlice(allocator, "\",\"kind\":\"terminal\",\"focusedSurfaceId\":\"");
        if (tab_state.focusedSurface()) |focused|
            try remote.appendJsonString(out, allocator, focused.remote_id[0..]);
        try out.appendSlice(allocator, "\",\"surfaces\":[");

        var spatial = tab_state.tree.spatial(allocator) catch null;
        defer if (spatial) |*sp| sp.deinit(allocator);

        var wrote_surface = false;
        var it = tab_state.tree.surfaces();
        while (it.next()) |entry| {
            if (wrote_surface) try out.append(allocator, ',');
            wrote_surface = true;
            try out.appendSlice(allocator, "{\"id\":\"");
            try remote.appendJsonString(out, allocator, entry.surface.remote_id[0..]);
            try out.appendSlice(allocator, "\",\"title\":\"");
            try remote.appendJsonString(out, allocator, entry.surface.getTitle());
            try out.appendSlice(allocator, "\",\"focused\":");
            try out.appendSlice(allocator, if (entry.handle == tab_state.focused) "true" else "false");
            try appendAgentDetectionJson(allocator, out, entry.surface);
            try out.appendSlice(allocator, ",\"cols\":");
            try out.print(allocator, "{d}", .{entry.surface.size.grid.cols});
            try out.appendSlice(allocator, ",\"rows\":");
            try out.print(allocator, "{d}", .{entry.surface.size.grid.rows});
            var cx: usize = 0;
            var cy: usize = 0;
            {
                entry.surface.render_state.mutex.lock();
                defer entry.surface.render_state.mutex.unlock();
                cx = entry.surface.terminal.screens.active.cursor.x;
                cy = entry.surface.terminal.screens.active.cursor.y;
            }
            try out.appendSlice(allocator, ",\"cursorX\":");
            try out.print(allocator, "{d}", .{cx});
            try out.appendSlice(allocator, ",\"cursorY\":");
            try out.print(allocator, "{d}", .{cy});
            try out.appendSlice(allocator, ",\"cwd\":\"");
            if (entry.surface.getCwd()) |cwd| try remote.appendJsonString(out, allocator, cwd);
            try out.append(allocator, '"');
            if (spatial) |sp| {
                const slot = sp.slots[entry.handle.idx()];
                try out.print(allocator, ",\"x\":{d:.5},\"y\":{d:.5},\"w\":{d:.5},\"h\":{d:.5}", .{
                    @as(f64, @floatCast(slot.x)),    @as(f64, @floatCast(slot.y)),
                    @as(f64, @floatCast(slot.width)), @as(f64, @floatCast(slot.height)),
                });
            } else {
                try out.appendSlice(allocator, ",\"x\":0,\"y\":0,\"w\":1,\"h\":1");
            }
            try out.append(allocator, '}');
        }
        try out.appendSlice(allocator, "]}");
    }
    try out.appendSlice(allocator, "]}");
}
```

- [ ] **Step 3: Call `syncCtlPanes(allocator);` immediately after `syncRemoteLayout(allocator);` (AppWindow.zig ~6889).**

- [ ] **Step 4: Add the cross-platform-safety unit test (mirror the agent-callback test ~line 5071).**

```zig
test "ctl surface callbacks reject an unregistered id without dereferencing" {
    try std.testing.expect((try ctlGetText(&g_ctl_ctx, std.testing.allocator, "missing", null)) == null);
    try std.testing.expect(!ctlSendText(&g_ctl_ctx, "missing", "x"));
}
```

- [ ] **Step 5: Run** — `zig build test-full` → PASS.
- [ ] **Step 6: Commit** — `feat(ctl): AppWindow Control impl (registry get/send + UI-published panes)`

---

## Task 7: App.zig + main.zig wiring + config keys

**Files:**
- Modify: `src/App.zig`, `src/main.zig`, `src/config.zig`

- [ ] **Step 1: config.zig — add keys + apply + usage.**
  - Field block (near `weixin-direct-enabled`, line ~369):
    ```zig
    /// Enable the local agent terminal control API (wisptermctl). Binds
    /// 127.0.0.1 only; a random token is written to <config-dir>/agent-control.json (0600).
    @"agent-control-enabled": bool = false,
    /// Fixed loopback port for the control API (0 = OS-assigned).
    @"agent-control-port": u16 = 0,
    ```
  - In `applyKeyValue` (mirror weixin-direct-enabled bool parse + add u16 parse):
    ```zig
    } else if (std.mem.eql(u8, key, "agent-control-enabled")) {
        if (parseBoolLike(value)) |b| self.@"agent-control-enabled" = b else log.warn("invalid agent-control-enabled: {s}", .{value});
    } else if (std.mem.eql(u8, key, "agent-control-port")) {
        self.@"agent-control-port" = std.fmt.parseInt(u16, std.mem.trim(u8, value, " "), 10) catch self.@"agent-control-port";
    ```
    (Match the exact bool-parse idiom already used for weixin-direct-enabled at config.zig:905-911.)
  - Add usage lines + a sample-config block mirroring the weixin ones.

- [ ] **Step 2: App.zig — field + start + shutdown.**
  - Import: `const ctl_server = @import("ctl/server.zig");` `const ctl_discovery = @import("ctl/discovery.zig");`
  - Field (near `weixin_controller`): `agent_control_server: ?*ctl_server.Server = null,` (and init `= null` in App.init).
  - Start (mirror startWeixin; call from main after startWeixin):
    ```zig
    pub fn startAgentControl(self: *App, cfg: *const Config) void {
        if (!cfg.@"agent-control-enabled") return;
        var token_bytes: [16]u8 = undefined;
        std.crypto.random.bytes(&token_bytes);
        var token_hex: [32]u8 = undefined;
        _ = std.fmt.bufPrint(&token_hex, "{x}", .{std.fmt.fmtSliceHexLower(&token_bytes)}) catch return;
        const server = ctl_server.Server.create(self.allocator, AppWindow.agentControl(), &token_hex, cfg.@"agent-control-port") catch |err| {
            std.debug.print("agent-control disabled: {}\n", .{err});
            return;
        };
        ctl_discovery.write(self.allocator, .{ .port = server.port, .token = server.token }) catch {};
        server.start() catch {
            server.destroy();
            return;
        };
        self.agent_control_server = server;
        AppWindow.enableAgentControl();
        std.debug.print("agent-control listening on 127.0.0.1:{d}\n", .{server.port});
    }
    ```
    > Confirm 0.15.2 hex-format spelling (`fmtSliceHexLower` vs `{x}` on the slice). Adjust to whatever the stdlib exposes; the goal is 32 lowercase hex chars.
  - Shutdown (in deinit, near weixin teardown):
    ```zig
    if (self.agent_control_server) |server| {
        server.destroy();
        self.agent_control_server = null;
        ctl_discovery.remove(self.allocator);
    }
    ```

- [ ] **Step 3: main.zig — after `app.startWeixin(&cfg);` add `app.startAgentControl(&cfg);`**

- [ ] **Step 4: App.zig test — start/stop is clean when disabled and when enabled (auto-port).**
  ```zig
  test "agent-control server starts on an auto port and stops cleanly" {
      // reuse the existing App test scaffold; set cfg.@"agent-control-enabled"=true,
      // call startAgentControl, expect agent_control_server != null and port != 0,
      // then app.deinit() must not hang.
  }
  ```
  (If wiring a full App in a unit test is heavy, instead assert `Server.create(...,0)` + `start` + `destroy` directly — already covered by Task 5's posix test. A disabled-path assertion `startAgentControl` is a no-op is cheap and sufficient here.)

- [ ] **Step 5: Run** — `zig build test-full` → PASS.
- [ ] **Step 6: Commit** — `feat(ctl): wire server into App lifecycle + config keys`

---

## Task 8: `ctl/client.zig` + `wisptermctl.zig` + build target

**Files:**
- Create: `src/ctl/client.zig`, `src/wisptermctl.zig`
- Modify: `build.zig`, `src/test_fast.zig`

- [ ] **Step 1: `ctl/client.zig` — pure helpers (tested) + thin socket call.**

```zig
//! wisptermctl client logic: arg parsing, escape decoding, wait-for matching,
//! and a one-shot request/response over a loopback stream. Pure helpers are
//! unit-tested; the socket call is thin.
const std = @import("std");
const protocol = @import("protocol.zig");

pub const Action = union(enum) {
    panes,
    get_text: struct { id: []const u8, recent: ?u32 },
    send_text: struct { id: []const u8, data: []const u8 }, // data = decoded bytes
    wait_for: struct { id: []const u8, pattern: []const u8, timeout_ms: u32 },
    help,
};

/// Decode C-style escapes (\n \r \t \\ \xNN) into raw bytes. Caller owns.
pub fn decodeEscapes(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] != '\\' or i + 1 >= s.len) {
            try out.append(allocator, s[i]);
            continue;
        }
        i += 1;
        switch (s[i]) {
            'n' => try out.append(allocator, '\n'),
            'r' => try out.append(allocator, '\r'),
            't' => try out.append(allocator, '\t'),
            '0' => try out.append(allocator, 0),
            '\\' => try out.append(allocator, '\\'),
            'x' => {
                if (i + 2 < s.len) {
                    const hi = std.fmt.charToDigit(s[i + 1], 16) catch { try out.append(allocator, '\\'); try out.append(allocator, 'x'); continue; };
                    const lo = std.fmt.charToDigit(s[i + 2], 16) catch { try out.append(allocator, '\\'); try out.append(allocator, 'x'); continue; };
                    try out.append(allocator, hi * 16 + lo);
                    i += 2;
                } else try out.append(allocator, 'x');
            },
            else => {
                try out.append(allocator, '\\');
                try out.append(allocator, s[i]);
            },
        }
    }
    return out.toOwnedSlice(allocator);
}

/// True if `haystack` contains `needle` (MVP wait-for = literal substring).
pub fn waitMatch(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

/// Parse argv[1..] into an Action. `args` are the post-program tokens.
pub fn parseArgs(args: []const []const u8) !Action {
    if (args.len == 0) return .help;
    const cmd = args[0];
    if (std.mem.eql(u8, cmd, "panes")) return .panes;
    if (std.mem.eql(u8, cmd, "get-text")) {
        const id = try flagValue(args, "-t") orelse return error.MissingTarget;
        const recent = if (try flagValue(args, "--recent")) |r| try std.fmt.parseInt(u32, r, 10) else null;
        return .{ .get_text = .{ .id = id, .recent = recent } };
    }
    if (std.mem.eql(u8, cmd, "send-text")) {
        const id = try flagValue(args, "-t") orelse return error.MissingTarget;
        const text = positionalAfterFlags(args) orelse return error.MissingText;
        return .{ .send_text = .{ .id = id, .data = text } }; // caller decodes escapes
    }
    if (std.mem.eql(u8, cmd, "wait-for")) {
        const id = try flagValue(args, "-t") orelse return error.MissingTarget;
        const pat = positionalAfterFlags(args) orelse return error.MissingText;
        const timeout = if (try flagValue(args, "--timeout")) |s| (try std.fmt.parseInt(u32, s, 10)) * 1000 else 60_000;
        return .{ .wait_for = .{ .id = id, .pattern = pat, .timeout_ms = timeout } };
    }
    return .help;
}

fn flagValue(args: []const []const u8, flag: []const u8) !?[]const u8 {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], flag)) {
            if (i + 1 >= args.len) return error.MissingFlagValue;
            return args[i + 1];
        }
    }
    return null;
}

/// First arg (after cmd) that is neither a known flag nor a flag value.
fn positionalAfterFlags(args: []const []const u8) ?[]const u8 {
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-t") or std.mem.eql(u8, a, "--recent") or std.mem.eql(u8, a, "--timeout")) {
            i += 1; // skip its value
            continue;
        }
        return a;
    }
    return null;
}

// ---- tests ----
const t = std.testing;
test "decodeEscapes handles \\n \\t \\x1b" {
    const out = try decodeEscapes(t.allocator, "a\\tb\\nc\\x1bd");
    defer t.allocator.free(out);
    try t.expectEqualSlices(u8, &[_]u8{ 'a', '\t', 'b', '\n', 'c', 0x1b, 'd' }, out);
}
test "waitMatch substring" {
    try t.expect(waitMatch("...done.", "done"));
    try t.expect(!waitMatch("running", "done"));
}
test "parseArgs" {
    try t.expectEqual(Action.panes, try parseArgs(&.{"panes"}));
    const g = try parseArgs(&.{ "get-text", "-t", "s1", "--recent", "200" });
    try t.expectEqualStrings("s1", g.get_text.id);
    try t.expectEqual(@as(?u32, 200), g.get_text.recent);
    const s = try parseArgs(&.{ "send-text", "-t", "s1", "ls\\n" });
    try t.expectEqualStrings("ls\\n", s.send_text.data);
    const w = try parseArgs(&.{ "wait-for", "-t", "s1", "done", "--timeout", "5" });
    try t.expectEqual(@as(u32, 5000), w.wait_for.timeout_ms);
    try t.expectError(error.MissingTarget, parseArgs(&.{"get-text"}));
}
```

- [ ] **Step 2: `wisptermctl.zig` — the exe main.**
  - Reads discovery (`ctl_discovery.read`). If absent → stderr "WispTerm agent control is not enabled..." exit 1.
  - `parseArgs(argv[1..])`. For `send_text`, `decodeEscapes(data)`. Build `protocol.Request` with token from discovery.
  - One connect-send-recv per request via `std.net.tcpConnectToAddress` + `protocol.encodeRequest` + read line + `protocol.parseResponse`. Print `result_text` (get-text) / `result_raw` (panes) to stdout; on `!ok` print error to stderr, exit 1.
  - `wait_for`: loop — every 500ms do a get-text request, `waitMatch(text, pattern)`; success → exit 0; on timeout → stderr + exit 2.
  - `help` → usage text.

  ```zig
  const std = @import("std");
  const protocol = @import("ctl/protocol.zig");
  const discovery = @import("ctl/discovery.zig");
  const client = @import("ctl/client.zig");

  pub fn main() !void {
      var gpa = std.heap.GeneralPurposeAllocator(.{}){};
      defer _ = gpa.deinit();
      const allocator = gpa.allocator();

      const raw_args = try std.process.argsAlloc(allocator);
      defer std.process.argsFree(allocator, raw_args);
      const action = client.parseArgs(raw_args[1..]) catch |err| {
          try printUsage();
          return err;
      };
      if (action == .help) return printUsage();

      const info = (try discovery.read(allocator)) orelse {
          try std.fs.File.stderr().deprecatedWriter().writeAll("wisptermctl: agent control not enabled (set agent-control-enabled = true)\n");
          std.process.exit(1);
      };
      defer allocator.free(info.token);

      switch (action) {
          .panes => try runOnce(allocator, info, .{ .token = info.token, .cmd = .panes }, .raw),
          .get_text => |g| try runOnce(allocator, info, .{ .token = info.token, .cmd = .get_text, .id = g.id, .recent = g.recent }, .text),
          .send_text => |s| {
              const data = try client.decodeEscapes(allocator, s.data);
              defer allocator.free(data);
              try runOnce(allocator, info, .{ .token = info.token, .cmd = .send_text, .id = s.id, .data = data }, .ok_only);
          },
          .wait_for => |w| try runWaitFor(allocator, info, w),
          .help => try printUsage(),
      }
  }
  // ... runOnce / runWaitFor / printUsage helpers (use std.net.tcpConnectToAddress).
  ```
  > Confirm 0.15.2 stdout/stderr writer spelling (`std.fs.File.stdout().deprecatedWriter()` is what ssh_askpass.zig uses — reuse that exact idiom).

- [ ] **Step 3: build.zig — add the `wisptermctl` exe target** (after the askpass block, inside `if (emit_desktop_exe)` or unconditionally for desktop targets):
  ```zig
  const ctl_mod = b.createModule(.{
      .root_source_file = b.path("src/wisptermctl.zig"),
      .target = target,
      .optimize = optimize,
  });
  const ctl_exe = b.addExecutable(.{ .name = "wisptermctl", .root_module = ctl_mod });
  if (platform.supports_gui_subsystem) ctl_exe.subsystem = .Console; // always console: it's a CLI
  b.installArtifact(ctl_exe);
  ```
  > `wisptermctl.zig` imports only `ctl/*` + `platform/dirs.zig` (std/builtin) → no GUI/SDL deps. Verify it links with no system libs on each target.

- [ ] **Step 4: Add `_ = @import("ctl/client.zig");` to `src/test_fast.zig`.**
- [ ] **Step 5: Run** — `zig build test` (client helpers) + `zig build` (wisptermctl compiles + installs) → PASS.
- [ ] **Step 6: Commit** — `feat(ctl): wisptermctl client exe + pure client helpers`

---

## Task 9: Docs + full-suite verification

**Files:**
- Create: `docs/agent-control.md` (or extend `docs/ai-agent.md`)

- [ ] **Step 1: Write user docs** — enable via `agent-control-enabled = true`; the 4 commands with examples; auth/discovery file; cross-platform note; limitations (substring wait-for, no exit-status, no remote mode).
- [ ] **Step 2: Run the full matrix:**
  - `zig build test` → PASS
  - `zig build test-full` → PASS (incl. posix round-trip)
  - `zig build` (host) → builds `wispterm` + `wisptermctl`
  - cross-compile sanity: `zig build -Dtarget=x86_64-windows-gnu` (the suite's usual cross target) → builds.
- [ ] **Step 3: Manual smoke (documented, GUI-pending):** launch app with `agent-control-enabled = true`; `wisptermctl panes`; `wisptermctl send-text -t <id> "echo hi\n"`; `wisptermctl get-text -t <id>`; `wisptermctl wait-for -t <id> "hi" --timeout 5`.
- [ ] **Step 4: Commit** — `docs(ctl): agent terminal control API usage`

---

## Out of MVP scope (issue P2/P3 — do NOT build here)
- Named special keys (`<enter>`/`<ctrl-c>`) as a `send-keys` command (the control-key map exists in `ai_chat_tools.zig`).
- `exit-status` / `last-activity` metadata.
- Full regex `wait-for` (MVP = literal substring; document clearly).
- Herdr-style `--remote` (needs cross-platform WS transport).
- Keep-alive multi-request connections; per-connection threads + recv timeouts (MVP = one request per connection, trusted localhost).
- Settings-page UI toggle / read-only / confirmation modes.

## Risk register (adversarial review focus after impl)
1. **Lock hold time:** `surface_registry` global lock held across `get-text` snapshot serialization — matches the agent path; cap rows (default 1000) keeps it bounded.
2. **Server shutdown:** accept unblocked via self-connect; verify `destroy()` never hangs (posix test exercises start→destroy).
3. **JSON safety:** arbitrary terminal bytes (control chars, quotes, invalid UTF-8) must survive `encodeOkText` → `parseResponse`. `std.json.Stringify` escapes control chars; **verify behavior on invalid UTF-8** (may need `escape_unicode`/lossy handling) — add a test with raw `0x80` bytes.
4. **Token:** constant-time compare, 127.0.0.1-only bind, `0600` discovery file. Confirm bind cannot fall back to all-interfaces.
5. **Zig 0.15.2 stdlib spellings:** `std.json.Stringify.valueAlloc`, `readFileAlloc` arg order, hex format, stdout/stderr writer — verified against existing call sites during impl; fix at first compile error.
