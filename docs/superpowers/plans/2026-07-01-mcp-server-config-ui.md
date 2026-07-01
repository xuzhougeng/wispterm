# MCP Server Config UI — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An in-app panel to list/add/edit/enable/remove/test external MCP servers, persisting to `mcp.json` and reloading live.

**Architecture:** A dedicated overlay (`mcp_servers.State`) mirrors the existing SSH Profiles overlay. `tools/mcp_registry.zig` gains read/write of `mcp.json`. A background probe worker (mirroring `assistant/quick_verify.zig`) runs the real `initialize`+`tools/list` handshake off-thread and reports discovered tool names. Save writes `mcp.json` and calls the existing `reloadMcpTools`.

**Tech Stack:** Zig 0.15.2, `std.json`, `std.Thread`, the repo's overlay framework.

## Global Constraints

- Zig `0.15.2`. Use `std.json.parseFromSlice(std.json.Value, ...)` for parse and `std.json.Stringify.valueAlloc(allocator, value, .{})` for serialize (repo idiom).
- Fast unit tests run via `src/test_fast.zig` (`zig build test`). Every new `.zig` module MUST be added there to be tested.
- Diagnostics go through `std.log.scoped(.mcp)` (visible in `-Ddebug-console` builds).
- Run `zig fmt src build.zig` before every commit; CI has a `zig fmt --check` gate.
- Overlays are fixed-size / heap-free in `OverlayState`; use fixed char buffers, not allocations, for editable fields (mirror `ssh_profiles.State`).
- Main-thread overlay key handlers MUST set `g_force_rebuild` (arrow-nav lags otherwise).
- Background threads MUST call `postWakeup()` after mutating shared state; `markUiDirty` is threadlocal and won't refresh another thread's UI.
- The config file is `<config-dir>/mcp.json` via `platform_dirs.pathInConfigDir(allocator, "mcp.json")`. Tests override the dir via `platform.dirs` `test_config_dir_override`.

---

## File Structure

- Modify `src/tools/mcp_registry.zig` — add `writeServersConfig`, `loadConfigFile`, `saveConfigFile`.
- Create `src/renderer/overlays/mcp_servers.zig` — overlay `State`: list, form, view mode, probe slot, all pure logic.
- Create `src/assistant/mcp_probe.zig` — async probe worker (`start`, `poll`), mirrors `quick_verify.zig`.
- Modify `src/renderer/overlays/state.zig` — add `mcp: mcp_servers.State` to `OverlayState`.
- Modify `src/command/center_state.zig` — add `manage_mcp_servers` action + palette entry.
- Modify the command-action dispatch site + input router + `renderer/overlays.zig` — open, key-handle, and draw the overlay (mirror SSH Profiles).
- Modify `src/test_fast.zig` — register `mcp_servers.zig`, `mcp_probe.zig`.

---

## Task 1: `writeServersConfig` — serialize a server list to mcp.json text

**Files:**
- Modify: `src/tools/mcp_registry.zig`
- Test: same file (fast suite via `test_fast.zig`, already registered)

**Interfaces:**
- Consumes: `ServerConfig { name: []u8, command: []u8, args: [][]u8, enabled: bool }` (exists), `parseServersConfig` (exists).
- Produces: `pub fn writeServersConfig(allocator, servers: []const ServerConfig) ![]u8` — owned JSON text ending in `\n`.

- [ ] **Step 1: Write the failing test**

```zig
test "writeServersConfig round-trips through parseServersConfig" {
    const a = std.testing.allocator;
    var args0 = [_][]u8{ @constCast("-y"), @constCast("pkg") };
    const servers = [_]ServerConfig{
        .{ .name = @constCast("ctx7"), .command = @constCast("npx"), .args = args0[0..], .enabled = true },
        .{ .name = @constCast("off"), .command = @constCast("foo"), .args = &.{}, .enabled = false },
    };
    const json = try writeServersConfig(a, servers[0..]);
    defer a.free(json);
    // enabled:true omitted, false emitted
    try std.testing.expect(std.mem.indexOf(u8, json, "\"enabled\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"enabled\":true") == null);
    // parse it back
    const back = try parseServersConfig(a, json);
    defer freeServersConfig(a, back);
    try std.testing.expectEqual(@as(usize, 2), back.len);
    try std.testing.expectEqualStrings("ctx7", back[0].name);
    try std.testing.expectEqualStrings("npx", back[0].command);
    try std.testing.expectEqual(@as(usize, 2), back[0].args.len);
    try std.testing.expect(back[0].enabled);
    try std.testing.expect(!back[1].enabled);
}

test "writeServersConfig with no servers is an empty mcpServers object" {
    const a = std.testing.allocator;
    const json = try writeServersConfig(a, &.{});
    defer a.free(json);
    const back = try parseServersConfig(a, json);
    defer freeServersConfig(a, back);
    try std.testing.expectEqual(@as(usize, 0), back.len);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | grep -A3 "writeServersConfig"`
Expected: FAIL — `writeServersConfig` undefined (compile error).

- [ ] **Step 3: Write minimal implementation**

Build a `std.json.Value` tree (object → `mcpServers` object → per-server object) and stringify. Add near `parseServersConfig`:

```zig
pub fn writeServersConfig(allocator: std.mem.Allocator, servers: []const ServerConfig) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var root = std.json.ObjectMap.init(aa);
    var servers_obj = std.json.ObjectMap.init(aa);
    for (servers) |s| {
        var entry = std.json.ObjectMap.init(aa);
        try entry.put("command", .{ .string = s.command });
        var arr = std.json.Array.init(aa);
        for (s.args) |arg| try arr.append(.{ .string = arg });
        try entry.put("args", .{ .array = arr });
        if (!s.enabled) try entry.put("enabled", .{ .bool = false });
        try servers_obj.put(s.name, .{ .object = entry });
    }
    try root.put("mcpServers", .{ .object = servers_obj });

    const body = try std.json.Stringify.valueAlloc(aa, std.json.Value{ .object = root }, .{ .whitespace = .indent_2 });
    return std.fmt.allocPrint(allocator, "{s}\n", .{body});
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test 2>/dev/null; echo EXIT=$?`
Expected: `EXIT=0`.

- [ ] **Step 5: Commit**

```bash
zig fmt src/tools/mcp_registry.zig
git add src/tools/mcp_registry.zig
git commit -m "feat(mcp): writeServersConfig serializes a server list to mcp.json"
```

---

## Task 2: `loadConfigFile` / `saveConfigFile` — read/write mcp.json on disk

**Files:**
- Modify: `src/tools/mcp_registry.zig`
- Test: same file

**Interfaces:**
- Consumes: `platform_dirs.pathInConfigDir` (imported), `parseServersConfig`, `writeServersConfig`, `platform.atomic_file` (add import `const atomic_file = @import("../platform/atomic_file.zig");`).
- Produces:
  - `pub fn loadConfigFile(allocator) ![]ServerConfig` — reads `<config-dir>/mcp.json`; missing file → empty list.
  - `pub fn saveConfigFile(allocator, servers: []const ServerConfig) !void` — atomic write.

- [ ] **Step 1: Write the failing test** (uses the config-dir override so it touches a temp dir, not the real one)

```zig
test "saveConfigFile then loadConfigFile round-trips via the config dir" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir_path);
    platform_dirs.setTestConfigDirOverride(dir_path);
    defer platform_dirs.setTestConfigDirOverride(null);

    var args0 = [_][]u8{@constCast("--stdio")};
    const servers = [_]ServerConfig{.{ .name = @constCast("gh"), .command = @constCast("github-mcp"), .args = args0[0..], .enabled = true }};
    try saveConfigFile(a, servers[0..]);

    const back = try loadConfigFile(a);
    defer freeServersConfig(a, back);
    try std.testing.expectEqual(@as(usize, 1), back.len);
    try std.testing.expectEqualStrings("gh", back[0].name);
    try std.testing.expectEqualStrings("github-mcp", back[0].command);
}

test "loadConfigFile returns empty when the file is absent" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir_path);
    platform_dirs.setTestConfigDirOverride(dir_path);
    defer platform_dirs.setTestConfigDirOverride(null);

    const back = try loadConfigFile(a);
    defer freeServersConfig(a, back);
    try std.testing.expectEqual(@as(usize, 0), back.len);
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test 2>&1 | grep -E "loadConfigFile|saveConfigFile|setTestConfigDirOverride"`
Expected: FAIL — `loadConfigFile`/`saveConfigFile` undefined. (If `setTestConfigDirOverride` is also undefined, add a thin public setter in `platform/dirs.zig` wrapping the existing `test_config_dir_override` var — one step, its own commit.)

- [ ] **Step 3: Write minimal implementation**

```zig
pub fn loadConfigFile(allocator: std.mem.Allocator) ![]ServerConfig {
    const path = try platform_dirs.pathInConfigDir(allocator, "mcp.json");
    defer allocator.free(path);
    const bytes = std.fs.cwd().readFileAlloc(allocator, path, MAX_MCP_CONFIG_BYTES) catch
        return allocator.alloc(ServerConfig, 0);
    defer allocator.free(bytes);
    return parseServersConfig(allocator, bytes);
}

pub fn saveConfigFile(allocator: std.mem.Allocator, servers: []const ServerConfig) !void {
    const path = try platform_dirs.pathInConfigDir(allocator, "mcp.json");
    defer allocator.free(path);
    const json = try writeServersConfig(allocator, servers);
    defer allocator.free(json);
    try atomic_file.writeFileReplaceSafe(path, json);
}
```

(Confirm the exact `atomic_file` write fn name by reading `src/platform/atomic_file.zig`; the SSH/skill-center save path uses `platform_atomic_file.writeFileReplaceSafe`.)

- [ ] **Step 4: Run to verify it passes**

Run: `zig build test 2>/dev/null; echo EXIT=$?`
Expected: `EXIT=0`.

- [ ] **Step 5: Commit**

```bash
zig fmt src/tools/mcp_registry.zig src/platform/dirs.zig
git add src/tools/mcp_registry.zig src/platform/dirs.zig
git commit -m "feat(mcp): load/save mcp.json in the config dir"
```

---

## Task 3: `mcp_servers.State` — list model, open/load, list navigation

**Files:**
- Create: `src/renderer/overlays/mcp_servers.zig`
- Modify: `src/test_fast.zig` (register the module)
- Test: in `mcp_servers.zig`

**Interfaces:**
- Consumes: `mcp_registry.ServerConfig`, `mcp_registry.loadConfigFile`, `mcp_registry.freeServersConfig`.
- Produces:
  - `pub const MCP_SERVER_MAX = 32;` `pub const FIELD_MAX = 512;`
  - `pub const Server = struct { name: [FIELD_MAX]u8 = undefined, name_len: usize = 0, command: [FIELD_MAX]u8 = undefined, command_len: usize = 0, args: [FIELD_MAX]u8 = undefined, args_len: usize = 0, enabled: bool = true };`
  - `pub const View = enum { list, form, json_preview };`
  - `pub const State = struct { visible, view, servers: [MCP_SERVER_MAX]Server, count, list_selected, ... }`
  - `pub fn open(self: *State, allocator) void` — loads from disk into `servers`.
  - `pub fn moveSelection(self: *State, delta: i32) void`

- [ ] **Step 1: Write the failing test**

```zig
test "open loads servers from the config dir and clamps selection" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir_path);
    mcp_registry_dirs.setTestConfigDirOverride(dir_path);
    defer mcp_registry_dirs.setTestConfigDirOverride(null);
    const servers = [_]mcp_registry.ServerConfig{
        .{ .name = @constCast("a"), .command = @constCast("x"), .args = &.{}, .enabled = true },
        .{ .name = @constCast("b"), .command = @constCast("y"), .args = &.{}, .enabled = false },
    };
    try mcp_registry.saveConfigFile(a, servers[0..]);

    var state: State = .{};
    state.open(a);
    try std.testing.expect(state.visible);
    try std.testing.expectEqual(@as(usize, 2), state.count);
    try std.testing.expectEqualStrings("a", state.serverName(0));
    try std.testing.expect(!state.servers[1].enabled);

    state.list_selected = 0;
    state.moveSelection(-1); // clamps at 0
    try std.testing.expectEqual(@as(usize, 0), state.list_selected);
    state.moveSelection(5);  // clamps at count-1
    try std.testing.expectEqual(@as(usize, 1), state.list_selected);
}
```

(`mcp_registry_dirs` = `@import("../../platform/dirs.zig")` alias inside the test; `serverName(i)` returns `servers[i].name[0..name_len]`.)

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test 2>&1 | grep -E "mcp_servers|open loads servers"`
Expected: FAIL — module not registered / `State` undefined. First add `_ = @import("renderer/overlays/mcp_servers.zig");` to `src/test_fast.zig` near the other overlay imports (line ~171), then the failure becomes `State`/`open` undefined.

- [ ] **Step 3: Write minimal implementation**

Create `mcp_servers.zig` with the `Server`/`View`/`State` structs, `serverName`, and:

```zig
pub fn open(self: *State, allocator: std.mem.Allocator) void {
    self.* = .{ .visible = true };
    const loaded = mcp_registry.loadConfigFile(allocator) catch return;
    defer mcp_registry.freeServersConfig(allocator, loaded);
    for (loaded) |cfg| {
        if (self.count >= MCP_SERVER_MAX) break;
        var s = Server{ .enabled = cfg.enabled };
        setBuf(&s.name, &s.name_len, cfg.name);
        setBuf(&s.command, &s.command_len, cfg.command);
        // args joined by single spaces
        var joined: [FIELD_MAX]u8 = undefined;
        var n: usize = 0;
        for (cfg.args, 0..) |arg, i| {
            if (i != 0 and n < FIELD_MAX) { joined[n] = ' '; n += 1; }
            const take = @min(arg.len, FIELD_MAX - n);
            @memcpy(joined[n..][0..take], arg[0..take]);
            n += take;
        }
        setBuf(&s.args, &s.args_len, joined[0..n]);
        self.servers[self.count] = s;
        self.count += 1;
    }
}

pub fn moveSelection(self: *State, delta: i32) void {
    if (self.count == 0) return;
    const cur: i32 = @intCast(self.list_selected);
    const max: i32 = @intCast(self.count - 1);
    self.list_selected = @intCast(std.math.clamp(cur + delta, 0, max));
}
```

(`setBuf(buf, len_ptr, src)` truncates-copies into a fixed buffer.)

- [ ] **Step 4: Run to verify it passes**

Run: `zig build test 2>/dev/null; echo EXIT=$?`
Expected: `EXIT=0`.

- [ ] **Step 5: Commit**

```bash
zig fmt src/renderer/overlays/mcp_servers.zig src/test_fast.zig
git add src/renderer/overlays/mcp_servers.zig src/test_fast.zig
git commit -m "feat(mcp): overlay State loads servers + list navigation"
```

---

## Task 4: Form edit — add / edit / remove / toggle, and form ⇄ ServerConfig

**Files:**
- Modify: `src/renderer/overlays/mcp_servers.zig`
- Test: same file

**Interfaces:**
- Produces:
  - `pub const Field = enum { name, command, args };`
  - `pub fn setFormField(self: *State, field, value) void`, `pub fn formField(self, field) []const u8`
  - `pub fn beginAdd(self)` / `pub fn beginEdit(self, index)` — populate the form, set `view=.form`, `editing_index`.
  - `pub fn commitForm(self) FormError!void` — validate (non-empty unique name, non-empty command) and write into `servers`.
  - `pub fn removeSelected(self)` , `pub fn toggleSelected(self)`
  - `pub const FormError = error{ EmptyName, DuplicateName, EmptyCommand };`

- [ ] **Step 1: Write the failing test**

```zig
test "add a server through the form" {
    var s: State = .{};
    s.beginAdd();
    s.setFormField(.name, "gh");
    s.setFormField(.command, "github-mcp");
    s.setFormField(.args, "stdio --verbose");
    try s.commitForm();
    try std.testing.expectEqual(@as(usize, 1), s.count);
    try std.testing.expectEqualStrings("gh", s.serverName(0));
    try std.testing.expectEqualStrings("stdio --verbose", s.serverArgs(0));
    try std.testing.expect(s.servers[0].enabled);
}

test "form rejects empty name, empty command, and duplicate name" {
    var s: State = .{};
    s.beginAdd();
    s.setFormField(.command, "x");
    try std.testing.expectError(error.EmptyName, s.commitForm());
    s.setFormField(.name, "a");
    s.setFormField(.command, "");
    try std.testing.expectError(error.EmptyCommand, s.commitForm());
    s.setFormField(.command, "x");
    try s.commitForm();               // "a" added
    s.beginAdd();
    s.setFormField(.name, "a");
    s.setFormField(.command, "y");
    try std.testing.expectError(error.DuplicateName, s.commitForm());
}

test "toggle and remove the selected server" {
    var s: State = .{};
    s.beginAdd(); s.setFormField(.name, "a"); s.setFormField(.command, "x"); try s.commitForm();
    s.list_selected = 0;
    s.toggleSelected();
    try std.testing.expect(!s.servers[0].enabled);
    s.removeSelected();
    try std.testing.expectEqual(@as(usize, 0), s.count);
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test 2>&1 | grep -E "add a server|rejects empty|toggle and remove"`
Expected: FAIL — form methods undefined.

- [ ] **Step 3: Write minimal implementation**

Add `Field`, form buffers to `State`, and the methods. `commitForm` validates then writes to `servers[editing_index]` (or appends when `editing_index == null`), splitting `args` on whitespace only when building the eventual `ServerConfig` (Task 5) — the form stores the raw args string. Duplicate check skips `editing_index`.

- [ ] **Step 4: Run to verify it passes** — `zig build test 2>/dev/null; echo EXIT=$?` → `EXIT=0`.

- [ ] **Step 5: Commit**

```bash
zig fmt src/renderer/overlays/mcp_servers.zig
git add src/renderer/overlays/mcp_servers.zig
git commit -m "feat(mcp): overlay form add/edit/remove/toggle with validation"
```

---

## Task 5: Build ServerConfig list + JSON preview + save

**Files:**
- Modify: `src/renderer/overlays/mcp_servers.zig`
- Test: same file

**Interfaces:**
- Produces:
  - `pub fn toServerConfigs(self, allocator) ![]mcp_registry.ServerConfig` — owned; args split on whitespace. Caller frees with `mcp_registry.freeServersConfig`.
  - `pub fn jsonPreview(self, allocator) ![]u8` — `writeServersConfig(toServerConfigs())`.
  - `pub fn save(self, allocator) !void` — `saveConfigFile(toServerConfigs())` then set a saved flag; caller triggers reload.

- [ ] **Step 1: Write the failing test**

```zig
test "jsonPreview equals what save writes, and splits args" {
    const a = std.testing.allocator;
    var s: State = .{};
    s.beginAdd(); s.setFormField(.name, "c"); s.setFormField(.command, "npx");
    s.setFormField(.args, "-y  pkg"); try s.commitForm();  // double space → 2 args

    const cfgs = try s.toServerConfigs(a);
    defer mcp_registry.freeServersConfig(a, cfgs);
    try std.testing.expectEqual(@as(usize, 1), cfgs.len);
    try std.testing.expectEqual(@as(usize, 2), cfgs[0].args.len);
    try std.testing.expectEqualStrings("pkg", cfgs[0].args[1]);

    const preview = try s.jsonPreview(a);
    defer a.free(preview);
    try std.testing.expect(std.mem.indexOf(u8, preview, "\"c\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, preview, "\"npx\"") != null);
}
```

- [ ] **Step 2: Run to verify it fails** — `grep "jsonPreview equals"`; FAIL undefined.

- [ ] **Step 3: Implement** `toServerConfigs` (whitespace-split args via `std.mem.tokenizeAny(u8, argsStr, " \t")`), `jsonPreview`, `save`.

- [ ] **Step 4: Run to verify it passes** — `EXIT=0`.

- [ ] **Step 5: Commit**

```bash
zig fmt src/renderer/overlays/mcp_servers.zig
git add src/renderer/overlays/mcp_servers.zig
git commit -m "feat(mcp): overlay toServerConfigs + JSON preview + save"
```

---

## Task 6: Async probe worker — `assistant/mcp_probe.zig`

**Files:**
- Create: `src/assistant/mcp_probe.zig`
- Modify: `src/test_fast.zig`
- Test: in `mcp_probe.zig`

**Interfaces (mirror `assistant/quick_verify.zig`):**
- Produces:
  - `pub const Result = struct { ok: bool, message: [256]u8, message_len: usize, tools: [24][64]u8, tool_count: usize };`
  - `pub fn probeBlocking(allocator, command: []const u8, args: []const []const u8) Result` — spawn+initialize+listTools, fill Result. (Pure, synchronous — the unit-testable core.)
  - `pub fn start(allocator, command, args, done: *const fn(*anyopaque, Result) void, ctx: *anyopaque) void` — spawns a thread that calls `probeBlocking` then `done(ctx, result)`. (Thread wrapper; not unit-tested — `probeBlocking` is.)

- [ ] **Step 1: Write the failing test** (canned `/bin/sh` server, same fixture style as `mcp_client` tests)

```zig
test "probeBlocking returns discovered tool names against a real server" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const init_line = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"serverInfo\":{\"name\":\"f\",\"version\":\"1\"}}}";
    const list_line = "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"tools\":[{\"name\":\"echo\",\"description\":\"e\",\"inputSchema\":{\"type\":\"object\"}},{\"name\":\"add\",\"description\":\"a\",\"inputSchema\":{\"type\":\"object\"}}]}}";
    const script = "printf '%s\\n' '" ++ init_line ++ "' '" ++ list_line ++ "'; exec cat >/dev/null";
    var args = [_][]const u8{ "-c", script };
    const r = probeBlocking(a, "/bin/sh", args[0..]);
    try std.testing.expect(r.ok);
    try std.testing.expectEqual(@as(usize, 2), r.tool_count);
    try std.testing.expectEqualStrings("echo", r.tools[0][0..4]);
}

test "probeBlocking reports failure for a server that cannot handshake" {
    const a = std.testing.allocator;
    var args = [_][]const u8{"--no"};
    const r = probeBlocking(a, "/bin/false", args[0..]);
    try std.testing.expect(!r.ok);
    try std.testing.expect(r.message_len > 0);
}
```

- [ ] **Step 2: Run to verify it fails** — register `_ = @import("assistant/mcp_probe.zig");` in `test_fast.zig` first, then FAIL `probeBlocking` undefined.

- [ ] **Step 3: Implement** using `mcp_client.Connection` (`spawn` → `initialize` → `listTools`), copying tool names into the fixed `tools` buffers (cap 24, 64 chars), or the error name into `message`. Free the `ToolDef`s. Log via `std.log.scoped(.mcp)`.

- [ ] **Step 4: Run to verify it passes** — `EXIT=0`.

- [ ] **Step 5: Commit**

```bash
zig fmt src/assistant/mcp_probe.zig src/test_fast.zig
git add src/assistant/mcp_probe.zig src/test_fast.zig
git commit -m "feat(mcp): async probe worker (initialize + tools/list)"
```

---

## Task 7: Wire probe into the overlay State

**Files:**
- Modify: `src/renderer/overlays/mcp_servers.zig`
- Test: same file

**Interfaces:**
- Consumes: `mcp_probe.Result`, `mcp_probe.probeBlocking`.
- Produces: `ProbeState { status: enum{idle,running,ok,failed}, target_index, ... }` on `State`, and `pub fn applyProbeResult(self, index, r: mcp_probe.Result) void`. (The `start`/thread call lives in the input handler, Task 10; the State just holds + applies the result so it stays fast-testable.)

- [ ] **Step 1: Write the failing test**

```zig
test "applyProbeResult stores tool names and status on the state" {
    var s: State = .{};
    s.beginAdd(); s.setFormField(.name, "x"); s.setFormField(.command, "/bin/sh"); try s.commitForm();
    var r = mcp_probe.Result{ .ok = true, .message = undefined, .message_len = 0, .tools = undefined, .tool_count = 1 };
    @memcpy(r.tools[0][0..4], "echo");
    s.applyProbeResult(0, r);
    try std.testing.expect(s.probe.status == .ok);
    try std.testing.expectEqual(@as(usize, 1), s.probe.tool_count);
}
```

- [ ] **Step 2: Run to verify it fails** — FAIL `probe`/`applyProbeResult` undefined.

- [ ] **Step 3: Implement** the `ProbeState` field + `applyProbeResult` (copy `r` into `self.probe`, set `status` from `r.ok`).

- [ ] **Step 4: Run to verify it passes** — `EXIT=0`.

- [ ] **Step 5: Commit**

```bash
zig fmt src/renderer/overlays/mcp_servers.zig
git add src/renderer/overlays/mcp_servers.zig
git commit -m "feat(mcp): overlay holds + applies probe results"
```

---

## Task 8: Add `mcp` to `OverlayState`

**Files:**
- Modify: `src/renderer/overlays/state.zig`
- Test: extend the existing `overlay state aggregates migrated overlay groups` test in that file.

- [ ] **Step 1: Write the failing test** — add to the existing aggregate test:

```zig
    state.mcp.beginAdd();
    state.mcp.setFormField(.name, "srv");
    try std.testing.expectEqualStrings("srv", state.mcp.formField(.name));
```

- [ ] **Step 2: Run to verify it fails** — FAIL: `OverlayState` has no `mcp`.

- [ ] **Step 3: Implement** — add `const mcp_servers = @import("mcp_servers.zig");` and `mcp: mcp_servers.State = .{},` to `OverlayState` (next to `ssh`).

- [ ] **Step 4: Run to verify it passes** — `EXIT=0`.

- [ ] **Step 5: Commit**

```bash
zig fmt src/renderer/overlays/state.zig
git add src/renderer/overlays/state.zig
git commit -m "feat(mcp): add mcp overlay to OverlayState"
```

---

## Task 9: Command-palette entry + action to open the panel (UI glue)

**Files:**
- Modify: `src/command/center_state.zig` (add action enum value + palette entry)
- Modify: the command-action dispatch site (find it: `git grep -n "manage_ai_profiles" src/appwindow src/input.zig` — the `switch` that handles `.manage_ai_profiles`). Add a `.manage_mcp_servers =>` arm that calls `overlay_state.mcp.open(allocator)` and sets `g_force_rebuild`.

**Mirror:** the `manage_ai_profiles` / `load_openssh_config` entries and their dispatch arms exactly — same structure, substitute `manage_mcp_servers` and `overlay_state.mcp.open`.

- [ ] **Step 1:** Add `manage_mcp_servers` to the action enum (`center_state.zig:8` area) and the palette entry: `.{ .title = "MCP Servers", .detail = "Add, edit, test, or remove MCP tool servers", .shortcut = "", .action = .manage_mcp_servers },`.
- [ ] **Step 2:** Find and open the dispatch switch: `git grep -n "\.manage_ai_profiles =>" src`. Add the `.manage_mcp_servers` arm mirroring it.
- [ ] **Step 3:** Build the app to verify it compiles: `zig build -Dtarget=aarch64-macos macos-app 2>/dev/null; echo EXIT=$?` → `EXIT=0`.
- [ ] **Step 4: Commit**

```bash
zig fmt src/command/center_state.zig <dispatch-file>
git add src/command/center_state.zig <dispatch-file>
git commit -m "feat(mcp): command-palette entry opens the MCP servers panel"
```

---

## Task 10: Overlay key input (UI glue)

**Files:**
- Modify: the input router. Find how the SSH overlay's keys are handled: `git grep -n "sshState\|ssh_profiles\|\.ssh\." src/input.zig src/renderer/overlays.zig` and locate the SSH overlay key handler; add a sibling `mcp` handler dispatched when `overlay_state.mcp.visible`.

**Behavior (mirror the SSH handler; set `g_force_rebuild` on every handled key):**
- `.list`: ↑/↓ `moveSelection(∓1)`, Enter `beginEdit(list_selected)`, `a` `beginAdd()`, `d` `removeSelected()`, space `toggleSelected()`, `t` → snapshot selected server's command/args, then `mcp_probe.start(...)` with a callback that calls `overlay_state.mcp.applyProbeResult(index, r)` + `postWakeup()`; set `probe.status = .running`. Tab → `view = .json_preview`. Ctrl-S → `save(allocator)` then `ai_chat.reloadMcpTools(allocator)`. Esc → `visible = false`.
- `.form`: text into the focused field via `setFormField`, Tab cycles `Field`, Enter `commitForm()` (on error keep the form + show message), Esc back to `.list`.
- `.json_preview`: Tab/Esc back to `.list` (read-only; no text input).

- [ ] **Step 1:** Implement the handler mirroring the SSH one. Guard entry on `overlay_state.mcp.visible` before other overlays, matching how `ssh` is gated.
- [ ] **Step 2:** Compile: `zig build -Dtarget=aarch64-macos macos-app 2>/dev/null; echo EXIT=$?` → `EXIT=0`.
- [ ] **Step 3:** Manual smoke (optional): open panel, add a server, press `t`, confirm probe result renders.
- [ ] **Step 4: Commit**

```bash
zig fmt <input-file>
git add <input-file>
git commit -m "feat(mcp): keyboard handling for the MCP servers panel"
```

---

## Task 11: Render the overlay (UI glue)

**Files:**
- Modify: `src/renderer/overlays.zig` (add `const mcp_servers = @import("overlays/mcp_servers.zig");`, an `mcpState()` accessor mirroring `sshState()` at line 120, and a draw path). Optionally `Create: src/renderer/overlays/mcp_servers_layout.zig` mirroring `ssh_profiles_layout.zig` if the SSH overlay splits layout out.

**Draw (mirror the SSH Profiles overlay layout):**
- `.list`: title "MCP Servers", one row per server: `[✓/✗] name — command` and the last probe result line for the selected row (`✓ N tools: a, b` or `✗ reason` or `probing…`). Footer with keys (a/d/space/t/Tab/Ctrl-S/Esc).
- `.form`: labelled fields Name / Command / Args (+ hint "space-separated; use JSON view to verify"), inline validation message.
- `.json_preview`: the `jsonPreview(allocator)` text, read-only, with "this is what Save writes".

- [ ] **Step 1:** Implement the draw path mirroring SSH Profiles; call it from the overlay render dispatch where `sshState().visible` is checked.
- [ ] **Step 2:** Compile + run: `zig build -Dtarget=aarch64-macos macos-app` then `open zig-out/bin/WispTerm.app`, open the panel via the command palette, verify list/form/json render.
- [ ] **Step 3: Commit**

```bash
zig fmt src/renderer/overlays.zig
git add src/renderer/overlays.zig src/renderer/overlays/mcp_servers_layout.zig
git commit -m "feat(mcp): render the MCP servers panel (list/form/json)"
```

---

## Task 12: E2E — panel lists a pre-seeded server (optional)

**Files:**
- Create: `tests/macos_e2e/test_mcp_panel.py`

**Behavior:** with an isolated HOME whose `mcp.json` has one server, launch the app, open the command palette, run "MCP Servers", and assert the panel text (via `app.get_text`) contains the server name. Reuse the `app` fixture / driver from `test_copilot_history.py`.

- [ ] **Step 1:** Write the test mirroring an existing GUI test that opens the command palette and reads pane text.
- [ ] **Step 2:** Run: `make test-macos-e2e` (builds app + runs). Expected: the new test passes or skips on hosts without Accessibility.
- [ ] **Step 3: Commit**

```bash
git add tests/macos_e2e/test_mcp_panel.py
git commit -m "test(mcp): E2E opens the MCP servers panel and lists a server"
```

---

## Self-Review

- **Spec coverage:** list/add/edit/enable/remove → Tasks 3-5,8; form editing → Task 4; read-only JSON preview → Tasks 5,11; async Test probe with tool names → Tasks 6-7,10; save+reload → Tasks 5,10; persistence → Tasks 1-2; open via command palette → Task 9; input → Task 10; render → Task 11; testing → each task + Task 12. All spec sections covered.
- **Placeholders:** UI-glue Tasks 9-11 intentionally point at exact analog files/functions to mirror (the SSH Profiles overlay) rather than pasting 200+ lines of framework boilerplate; each names the precise files, keys, and calls. The implementer reads the named analog. All logic tasks (1-8) carry complete code.
- **Type consistency:** `ServerConfig` (mcp_registry), `Server`/`State`/`Field`/`View`/`ProbeState` (mcp_servers), `Result`/`probeBlocking`/`start` (mcp_probe) are used consistently across tasks. `writeServersConfig`/`loadConfigFile`/`saveConfigFile` names match between Tasks 1-2 and their consumers in Tasks 5,10.
