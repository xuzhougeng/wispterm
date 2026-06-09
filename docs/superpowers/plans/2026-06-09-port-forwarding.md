# Port Forwarding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a silent SSH local/reverse port-forwarding manager with a dedicated non-terminal Port Forwarding tab, global rules bound to saved SSH profiles, and startup auto-start support.

**Architecture:** Keep forwarding out of terminal surfaces: `App` owns a process-wide `port_forward_manager.Manager`; the Port Forwarding tab owns only UI selection/form state. Forwarding uses OpenSSH helper processes (`ssh -N -T -L/-R`) and reuses WispTerm's SSH profile, askpass, ProxyJump, legacy-algorithm, and child-cleanup conventions. Ghostty has no port-forwarding manager; its `ghostty +ssh` wrapper passes SSH args through to OpenSSH and only uses ControlMaster for short-lived terminfo installation, so WispTerm should keep this feature as OpenSSH helper orchestration rather than SSH protocol code.

**Tech Stack:** Zig 0.15, WispTerm App/AppWindow tab model, `std.process.Child`, OpenSSH (`ssh.exe` on Windows), existing `ssh_connection`, `platform/process`, `platform/pty_command`, `renderer/overlays/profile_codec`, Skill Center-style non-terminal tab rendering.

---

## File Structure

- Create `src/port_forward_rule.zig`: pure rule type, validation, hex line codec, default reverse rule, `-L/-R` forward spec builder, and helper argv fragment builder. This file is platform-independent and belongs in `src/test_fast.zig`.
- Create `src/ssh_profile_store.zig`: profile-file reader that turns saved `ssh_hosts` records into `ssh_connection.SshConnection` values without importing `overlays.zig` or mutating the SSH profile page. This keeps Port Forwarding independent from the existing SSH profile UI while reusing `profile_codec`.
- Create `src/port_forward_manager.zig`: app-owned rule list, runtime state, child process lifecycle, load/save to the platform config directory's `port_forwards` file, startup auto-start, start/stop/restart/tick operations, and snapshot callbacks for the renderer.
- Create `src/port_forwarding.zig`: UI-only panel/session model: selected row, scroll, in-tab form, confirmation state, and edit helpers. It does not own child processes.
- Create `src/renderer/port_forwarding_renderer.zig`: Skill Center-style table renderer and pure label/layout helpers.
- Modify `src/App.zig`: add app-owned manager, load rules during app init, start enabled auto-start rules, and stop children during app deinit.
- Modify `src/AppWindow.zig`: expose active Port Forwarding tab helpers, render the tab, route manager snapshots to the renderer, tick manager state, and add command-center action wrapper.
- Modify `src/appwindow/tab.zig`: add `port_forwarding` tab kind and session pointer.
- Modify `src/input.zig`: route Port Forwarding keys/chars before terminal input and set render dirty flags through AppWindow wrappers.
- Modify `src/command_center_state.zig`: add `open_port_forwarding` action and command entry.
- Modify `src/i18n.zig`: add English/Chinese labels and command search text.
- Modify `src/test_fast.zig` and `src/test_main.zig`: import the new pure/app modules.
- Create `docs/port-forwarding.md` and modify `README.md`: document reverse/local rules and the loopback-only v1 safety boundary.

## Dependency Order

1. `port_forward_rule.zig` first; every later module depends on the rule type and validation.
2. `ssh_profile_store.zig` second; manager needs profile resolution without touching the SSH profile UI.
3. `port_forward_manager.zig` third; UI and App lifecycle depend on its APIs.
4. `port_forwarding.zig` and `port_forwarding_renderer.zig` fourth; they depend on manager row snapshots.
5. App/tab/input/command/i18n wiring last; they depend on all previous APIs.
6. Docs and full verification after code compiles.

---

### Task 1: Pure Port-Forwarding Rule Model And Codec

**Files:**
- Create: `src/port_forward_rule.zig`
- Modify: `src/test_fast.zig`
- Test: `src/port_forward_rule.zig`

- [ ] **Step 1: Create failing rule-model tests**

Create `src/port_forward_rule.zig` with these tests and minimal imports only:

```zig
const std = @import("std");

test "port_forward_rule: default reverse rule targets local proxy" {
    const rule = defaultReverseProxy("devbox");
    try std.testing.expectEqual(Direction.reverse, rule.direction);
    try std.testing.expectEqualStrings("devbox", rule.profileName());
    try std.testing.expectEqualStrings("127.0.0.1", rule.localHost());
    try std.testing.expectEqual(@as(u16, 7890), rule.local_port);
    try std.testing.expectEqualStrings("127.0.0.1", rule.remoteHost());
    try std.testing.expectEqual(@as(u16, 7890), rule.remote_port);
    try std.testing.expect(rule.enabled);
    try std.testing.expect(rule.auto_start);
}

test "port_forward_rule: validates loopback hosts and port range" {
    try std.testing.expect(validateHost("127.0.0.1"));
    try std.testing.expect(validateHost("localhost"));
    try std.testing.expect(!validateHost("0.0.0.0"));
    try std.testing.expect(!validateHost("10.0.0.1"));
    try std.testing.expect(parsePort("1").? == 1);
    try std.testing.expect(parsePort("65535").? == 65535);
    try std.testing.expect(parsePort("0") == null);
    try std.testing.expect(parsePort("65536") == null);
    try std.testing.expect(parsePort("abc") == null);
}

test "port_forward_rule: forward specs match ssh -L and -R semantics" {
    var rule = defaultReverseProxy("devbox");
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "127.0.0.1:7890:127.0.0.1:7890",
        rule.forwardSpec(&buf).?,
    );
    try std.testing.expectEqualStrings("-R", rule.direction.flag());

    rule.direction = .local;
    rule.local_port = 8888;
    rule.remote_port = 8888;
    try std.testing.expectEqualStrings(
        "127.0.0.1:8888:127.0.0.1:8888",
        rule.forwardSpec(&buf).?,
    );
    try std.testing.expectEqualStrings("-L", rule.direction.flag());
}

test "port_forward_rule: storage round trips two rules" {
    var rules = [_]Rule{
        defaultReverseProxy("devbox"),
        defaultReverseProxy("lab"),
    };
    rules[1].direction = .local;
    rules[1].local_port = 8888;
    rules[1].remote_port = 8888;
    rules[1].auto_start = false;
    rules[1].setName("Jupyter");

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try encodeRules(std.testing.allocator, &out, rules[0..]);

    var decoded = try decodeRules(std.testing.allocator, out.items);
    defer freeRules(std.testing.allocator, decoded);

    try std.testing.expectEqual(@as(usize, 2), decoded.len);
    try std.testing.expectEqual(Direction.reverse, decoded[0].direction);
    try std.testing.expectEqualStrings("devbox", decoded[0].profileName());
    try std.testing.expectEqual(Direction.local, decoded[1].direction);
    try std.testing.expectEqualStrings("Jupyter", decoded[1].name());
    try std.testing.expect(!decoded[1].auto_start);
}
```

- [ ] **Step 2: Run the focused test to verify it fails**

Run:

```bash
zig test src/port_forward_rule.zig
```

Expected: FAIL with undefined identifiers such as `defaultReverseProxy`, `Direction`, and `Rule`.

- [ ] **Step 3: Implement the rule model, validation, spec builder, and codec**

Replace `src/port_forward_rule.zig` with this implementation, preserving the tests from Step 1 at the bottom:

```zig
const std = @import("std");

pub const NAME_MAX: usize = 96;
pub const PROFILE_MAX: usize = 128;
pub const HOST_MAX: usize = 64;

pub const Direction = enum {
    local,
    reverse,

    pub fn flag(self: Direction) []const u8 {
        return switch (self) {
            .local => "-L",
            .reverse => "-R",
        };
    }

    pub fn text(self: Direction) []const u8 {
        return switch (self) {
            .local => "local",
            .reverse => "reverse",
        };
    }

    pub fn parse(value: []const u8) ?Direction {
        if (std.ascii.eqlIgnoreCase(value, "local")) return .local;
        if (std.ascii.eqlIgnoreCase(value, "reverse")) return .reverse;
        return null;
    }
};

pub const Rule = struct {
    name_buf: [NAME_MAX]u8 = undefined,
    name_len: usize = 0,
    profile_buf: [PROFILE_MAX]u8 = undefined,
    profile_len: usize = 0,
    direction: Direction = .reverse,
    local_host_buf: [HOST_MAX]u8 = undefined,
    local_host_len: usize = 0,
    local_port: u16 = 7890,
    remote_host_buf: [HOST_MAX]u8 = undefined,
    remote_host_len: usize = 0,
    remote_port: u16 = 7890,
    enabled: bool = true,
    auto_start: bool = true,

    pub fn name(self: *const Rule) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    pub fn profileName(self: *const Rule) []const u8 {
        return self.profile_buf[0..self.profile_len];
    }

    pub fn localHost(self: *const Rule) []const u8 {
        return self.local_host_buf[0..self.local_host_len];
    }

    pub fn remoteHost(self: *const Rule) []const u8 {
        return self.remote_host_buf[0..self.remote_host_len];
    }

    pub fn setName(self: *Rule, value: []const u8) void {
        self.name_len = copyBounded(self.name_buf[0..], value);
    }

    pub fn setProfileName(self: *Rule, value: []const u8) void {
        self.profile_len = copyBounded(self.profile_buf[0..], value);
    }

    pub fn setLocalHost(self: *Rule, value: []const u8) void {
        self.local_host_len = copyBounded(self.local_host_buf[0..], value);
    }

    pub fn setRemoteHost(self: *Rule, value: []const u8) void {
        self.remote_host_len = copyBounded(self.remote_host_buf[0..], value);
    }

    pub fn validate(self: *const Rule) bool {
        return self.profileName().len > 0 and
            validateHost(self.localHost()) and
            validateHost(self.remoteHost()) and
            self.local_port != 0 and
            self.remote_port != 0;
    }

    pub fn forwardSpec(self: *const Rule, buf: []u8) ?[]const u8 {
        if (!self.validate()) return null;
        return switch (self.direction) {
            .local => std.fmt.bufPrint(
                buf,
                "{s}:{d}:{s}:{d}",
                .{ self.localHost(), self.local_port, self.remoteHost(), self.remote_port },
            ) catch null,
            .reverse => std.fmt.bufPrint(
                buf,
                "{s}:{d}:{s}:{d}",
                .{ self.remoteHost(), self.remote_port, self.localHost(), self.local_port },
            ) catch null,
        };
    }
};

pub fn defaultReverseProxy(profile_name: []const u8) Rule {
    var rule: Rule = .{};
    rule.setName("Local proxy");
    rule.setProfileName(profile_name);
    rule.direction = .reverse;
    rule.setLocalHost("127.0.0.1");
    rule.local_port = 7890;
    rule.setRemoteHost("127.0.0.1");
    rule.remote_port = 7890;
    rule.enabled = true;
    rule.auto_start = true;
    return rule;
}

pub fn validateHost(host: []const u8) bool {
    return std.ascii.eqlIgnoreCase(host, "127.0.0.1") or
        std.ascii.eqlIgnoreCase(host, "localhost");
}

pub fn parsePort(text: []const u8) ?u16 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return null;
    const value = std.fmt.parseInt(u32, trimmed, 10) catch return null;
    if (value == 0 or value > std.math.maxInt(u16)) return null;
    return @intCast(value);
}

pub fn freeRules(allocator: std.mem.Allocator, rules: []Rule) void {
    allocator.free(rules);
}

pub fn encodeRules(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), rules: []const Rule) !void {
    try out.appendSlice(allocator, "# WispTerm port forwarding rules. Fields are hex encoded: name, profile, direction, local_host, local_port, remote_host, remote_port, enabled, auto_start.\n");
    for (rules) |rule| {
        try appendHexField(allocator, out, rule.name());
        try out.append(allocator, '\t');
        try appendHexField(allocator, out, rule.profileName());
        try out.append(allocator, '\t');
        try appendHexField(allocator, out, rule.direction.text());
        try out.append(allocator, '\t');
        try appendHexField(allocator, out, rule.localHost());
        try out.append(allocator, '\t');
        var local_port_buf: [8]u8 = undefined;
        try appendHexField(allocator, out, std.fmt.bufPrint(&local_port_buf, "{d}", .{rule.local_port}) catch unreachable);
        try out.append(allocator, '\t');
        try appendHexField(allocator, out, rule.remoteHost());
        try out.append(allocator, '\t');
        var remote_port_buf: [8]u8 = undefined;
        try appendHexField(allocator, out, std.fmt.bufPrint(&remote_port_buf, "{d}", .{rule.remote_port}) catch unreachable);
        try out.append(allocator, '\t');
        try appendHexField(allocator, out, if (rule.enabled) "true" else "false");
        try out.append(allocator, '\t');
        try appendHexField(allocator, out, if (rule.auto_start) "true" else "false");
        try out.append(allocator, '\n');
    }
}

pub fn decodeRules(allocator: std.mem.Allocator, content: []const u8) ![]Rule {
    var rules: std.ArrayListUnmanaged(Rule) = .empty;
    errdefer rules.deinit(allocator);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trimRight(u8, line_raw, "\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (decodeRuleLine(line)) |rule| {
            try rules.append(allocator, rule);
        }
    }
    return rules.toOwnedSlice(allocator);
}

pub fn decodeRuleLine(line: []const u8) ?Rule {
    var fields: [9][128]u8 = undefined;
    var lens: [9]usize = .{0} ** 9;
    var parts = std.mem.splitScalar(u8, line, '\t');
    var idx: usize = 0;
    while (idx < fields.len) : (idx += 1) {
        const part = parts.next() orelse return null;
        lens[idx] = decodeHexField(part, fields[idx][0..]) orelse return null;
    }
    var rule: Rule = .{};
    rule.setName(fields[0][0..lens[0]]);
    rule.setProfileName(fields[1][0..lens[1]]);
    rule.direction = Direction.parse(fields[2][0..lens[2]]) orelse return null;
    rule.setLocalHost(fields[3][0..lens[3]]);
    rule.local_port = parsePort(fields[4][0..lens[4]]) orelse return null;
    rule.setRemoteHost(fields[5][0..lens[5]]);
    rule.remote_port = parsePort(fields[6][0..lens[6]]) orelse return null;
    rule.enabled = parseBool(fields[7][0..lens[7]]) orelse return null;
    rule.auto_start = parseBool(fields[8][0..lens[8]]) orelse return null;
    return rule;
}

fn parseBool(text: []const u8) ?bool {
    if (std.ascii.eqlIgnoreCase(text, "true")) return true;
    if (std.ascii.eqlIgnoreCase(text, "false")) return false;
    return null;
}

fn appendHexField(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), field: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (field) |ch| {
        try out.append(allocator, hex[ch >> 4]);
        try out.append(allocator, hex[ch & 0x0f]);
    }
}

fn decodeHexField(value: []const u8, out: []u8) ?usize {
    if (value.len % 2 != 0) return null;
    const len = @min(value.len / 2, out.len);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const hi = hexValue(value[i * 2]) orelse return null;
        const lo = hexValue(value[i * 2 + 1]) orelse return null;
        out[i] = (hi << 4) | lo;
    }
    return len;
}

fn hexValue(ch: u8) ?u8 {
    if (ch >= '0' and ch <= '9') return ch - '0';
    if (ch >= 'a' and ch <= 'f') return ch - 'a' + 10;
    if (ch >= 'A' and ch <= 'F') return ch - 'A' + 10;
    return null;
}

fn copyBounded(dest: []u8, text: []const u8) usize {
    const n = @min(dest.len, text.len);
    @memcpy(dest[0..n], text[0..n]);
    return n;
}
```

- [ ] **Step 4: Run focused tests**

Run:

```bash
zig test src/port_forward_rule.zig
```

Expected: PASS.

- [ ] **Step 5: Add the module to the fast suite**

In `src/test_fast.zig`, add this import after `ssh_connection.zig`:

```zig
    _ = @import("port_forward_rule.zig");
```

- [ ] **Step 6: Run the fast suite**

Run:

```bash
zig build test
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add src/port_forward_rule.zig src/test_fast.zig
git commit -m "feat(port-forward): add rule codec"
```

---

### Task 2: Saved SSH Profile Resolver For Background Forwarding

**Files:**
- Create: `src/ssh_profile_store.zig`
- Modify: `src/test_fast.zig`
- Test: `src/ssh_profile_store.zig`

- [ ] **Step 1: Create failing tests for profile resolution**

Create `src/ssh_profile_store.zig` with these tests and imports:

```zig
const std = @import("std");
const ssh_connection = @import("ssh_connection.zig");

test "ssh_profile_store: resolves connection from encoded ssh_hosts content" {
    var content: std.ArrayListUnmanaged(u8) = .empty;
    defer content.deinit(std.testing.allocator);
    try appendEncodedProfileForTest(std.testing.allocator, &content, &.{
        "devbox", "10.0.0.9", "alice", "secret", "2222", "jump@example.com:22",
    });

    const conn = findConnectionInContent(content.items, "devbox", true) orelse return error.ExpectedConnection;
    try std.testing.expectEqualStrings("alice", conn.user());
    try std.testing.expectEqualStrings("10.0.0.9", conn.host());
    try std.testing.expectEqualStrings("2222", conn.port());
    try std.testing.expectEqualStrings("secret", conn.password());
    try std.testing.expectEqualStrings("jump@example.com:22", conn.proxyJump());
    try std.testing.expect(conn.password_auth);
    try std.testing.expect(conn.legacy_algorithms);
}

test "ssh_profile_store: rejects unsafe profile fields" {
    var content: std.ArrayListUnmanaged(u8) = .empty;
    defer content.deinit(std.testing.allocator);
    try appendEncodedProfileForTest(std.testing.allocator, &content, &.{
        "bad", "host;rm -rf /", "alice", "", "22", "",
    });

    try std.testing.expect(findConnectionInContent(content.items, "bad", false) == null);
}
```

- [ ] **Step 2: Run the focused test to verify it fails**

Run:

```bash
zig test src/ssh_profile_store.zig
```

Expected: FAIL with undefined identifiers such as `appendEncodedProfileForTest` and `findConnectionInContent`.

- [ ] **Step 3: Implement resolver and tests**

Add this implementation above the tests in `src/ssh_profile_store.zig`:

```zig
const profile_codec = @import("renderer/overlays/profile_codec.zig");
const platform_dirs = @import("platform/dirs.zig");
const command_palette_model = @import("command_palette_model.zig");

pub fn connectionByName(allocator: std.mem.Allocator, profile_name: []const u8, legacy_algorithms: bool) ?ssh_connection.SshConnection {
    const path = platform_dirs.sshHostsPath(allocator) catch return null;
    defer allocator.free(path);
    const content = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch return null;
    defer allocator.free(content);
    return findConnectionInContent(content, profile_name, legacy_algorithms);
}

pub fn findConnectionInContent(content: []const u8, profile_name: []const u8, legacy_algorithms: bool) ?ssh_connection.SshConnection {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trimRight(u8, line_raw, "\r");
        if (line.len == 0 or line[0] == '#') continue;
        const profile = profile_codec.decodeSshProfileLine(line) orelse continue;
        if (!std.ascii.eqlIgnoreCase(profile_name, profile_codec.profileField(&profile, .name))) continue;
        return connectionFromProfile(&profile, legacy_algorithms);
    }
    return null;
}

pub fn connectionFromProfile(profile: *const profile_codec.SshProfile, legacy_algorithms: bool) ?ssh_connection.SshConnection {
    const host = profile_codec.profileField(profile, .ip);
    const user = profile_codec.profileField(profile, .user);
    const port = profile_codec.profileField(profile, .port);
    const password = profile_codec.profileField(profile, .password);
    const proxy_jump = profile_codec.profileField(profile, .proxy_jump);
    if (host.len == 0 or user.len == 0) return null;
    if (!isSshTokenSafe(host) or !isSshTokenSafe(user)) return null;
    if (port.len > 0 and !isPortTokenSafe(port)) return null;
    if (!command_palette_model.isProxyJumpSafe(proxy_jump)) return null;

    var conn: ssh_connection.SshConnection = .{};
    conn.host_len = copyBounded(conn.host_buf[0..], host);
    conn.user_len = copyBounded(conn.user_buf[0..], user);
    conn.port_len = copyBounded(conn.port_buf[0..], port);
    conn.password_len = copyBounded(conn.password_buf[0..], password);
    conn.proxy_jump_len = copyBounded(conn.proxy_jump_buf[0..], proxy_jump);
    conn.password_auth = password.len > 0;
    conn.legacy_algorithms = legacy_algorithms;
    return conn;
}

fn isSshTokenSafe(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |ch| {
        if (std.ascii.isAlphanumeric(ch)) continue;
        switch (ch) {
            '.', '-', '_', ':', '@' => {},
            else => return false,
        }
    }
    return true;
}

fn isPortTokenSafe(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |ch| {
        if (!std.ascii.isDigit(ch)) return false;
    }
    return true;
}

fn copyBounded(dest: []u8, text: []const u8) usize {
    const n = @min(dest.len, text.len);
    @memcpy(dest[0..n], text[0..n]);
    return n;
}

fn appendEncodedProfileForTest(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), fields: []const []const u8) !void {
    for (fields, 0..) |field, idx| {
        if (idx > 0) try out.append(allocator, '\t');
        try appendHexFieldForTest(allocator, out, field);
    }
    try out.append(allocator, '\n');
}

fn appendHexFieldForTest(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), field: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (field) |ch| {
        try out.append(allocator, hex[ch >> 4]);
        try out.append(allocator, hex[ch & 0x0f]);
    }
}
```

- [ ] **Step 4: Run focused tests**

Run:

```bash
zig test src/ssh_profile_store.zig
```

Expected: PASS.

- [ ] **Step 5: Add the module to the fast suite**

In `src/test_fast.zig`, add this import after `port_forward_rule.zig`:

```zig
    _ = @import("ssh_profile_store.zig");
```

- [ ] **Step 6: Run the fast suite**

Run:

```bash
zig build test
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add src/ssh_profile_store.zig src/test_fast.zig
git commit -m "feat(port-forward): resolve saved ssh profiles"
```

---

### Task 3: Port Forward Manager State, Persistence, And Status Transitions

**Files:**
- Create: `src/port_forward_manager.zig`
- Modify: `src/test_fast.zig`
- Test: `src/port_forward_manager.zig`

- [ ] **Step 1: Create failing manager-state tests**

Create `src/port_forward_manager.zig` with these tests and imports:

```zig
const std = @import("std");
const rule_mod = @import("port_forward_rule.zig");

test "port_forward_manager: add save load and toggle auto start" {
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();

    try manager.addRule(rule_mod.defaultReverseProxy("devbox"));
    try std.testing.expectEqual(@as(usize, 1), manager.count());
    try std.testing.expect(manager.rowAt(0).?.auto_start);

    try std.testing.expect(manager.toggleAutoStart(0));
    try std.testing.expect(!manager.rowAt(0).?.auto_start);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try manager.encode(std.testing.allocator, &out);

    var loaded = Manager.init(std.testing.allocator);
    defer loaded.deinit();
    try loaded.loadFromContent(out.items);
    try std.testing.expectEqual(@as(usize, 1), loaded.count());
    try std.testing.expect(!loaded.rowAt(0).?.auto_start);
}

test "port_forward_manager: missing profile records status without spawning" {
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    try manager.addRule(rule_mod.defaultReverseProxy("missing"));

    const started = manager.markMissingProfileForTest(0);
    try std.testing.expect(!started);
    const row = manager.rowAt(0).?;
    try std.testing.expectEqual(StatusKind.missing_profile, row.status);
    try std.testing.expectEqualStrings("profile missing", row.reason);
}
```

- [ ] **Step 2: Run the focused test to verify it fails**

Run:

```bash
zig test src/port_forward_manager.zig
```

Expected: FAIL with undefined identifiers such as `Manager` and `StatusKind`.

- [ ] **Step 3: Implement manager state without child spawning**

Add this implementation above the tests:

```zig
pub const MAX_RULES: usize = 128;
pub const REASON_MAX: usize = 192;

pub const StatusKind = enum {
    stopped,
    starting,
    running,
    error_,
    missing_profile,
};

pub const RowView = struct {
    rule: rule_mod.Rule,
    status: StatusKind,
    reason: []const u8,
    auto_start: bool,
};

const Entry = struct {
    rule: rule_mod.Rule,
    status: StatusKind = .stopped,
    reason_buf: [REASON_MAX]u8 = undefined,
    reason_len: usize = 0,

    fn reason(self: *const Entry) []const u8 {
        return self.reason_buf[0..self.reason_len];
    }

    fn setStatus(self: *Entry, status: StatusKind, reason: []const u8) void {
        self.status = status;
        self.reason_len = copyBounded(self.reason_buf[0..], reason);
    }
};

pub const Manager = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    entries: std.ArrayListUnmanaged(Entry) = .empty,

    pub fn init(allocator: std.mem.Allocator) Manager {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Manager) void {
        self.stopAll();
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn count(self: *Manager) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.entries.items.len;
    }

    pub fn rowAt(self: *Manager, index: usize) ?RowView {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (index >= self.entries.items.len) return null;
        const entry = &self.entries.items[index];
        return .{
            .rule = entry.rule,
            .status = entry.status,
            .reason = entry.reason(),
            .auto_start = entry.rule.auto_start,
        };
    }

    pub fn addRule(self: *Manager, rule: rule_mod.Rule) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.entries.items.len >= MAX_RULES) return error.TooManyRules;
        try self.entries.append(self.allocator, .{ .rule = rule });
    }

    pub fn updateRule(self: *Manager, index: usize, rule: rule_mod.Rule) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (index >= self.entries.items.len) return false;
        self.entries.items[index].rule = rule;
        self.entries.items[index].setStatus(.stopped, "");
        return true;
    }

    pub fn deleteRule(self: *Manager, index: usize) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (index >= self.entries.items.len) return false;
        _ = self.entries.orderedRemove(index);
        return true;
    }

    pub fn toggleAutoStart(self: *Manager, index: usize) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (index >= self.entries.items.len) return false;
        self.entries.items[index].rule.auto_start = !self.entries.items[index].rule.auto_start;
        return true;
    }

    pub fn encode(self: *Manager, allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var rules = try allocator.alloc(rule_mod.Rule, self.entries.items.len);
        defer allocator.free(rules);
        for (self.entries.items, 0..) |entry, i| rules[i] = entry.rule;
        try rule_mod.encodeRules(allocator, out, rules);
    }

    pub fn loadFromContent(self: *Manager, content: []const u8) !void {
        const rules = try rule_mod.decodeRules(self.allocator, content);
        defer rule_mod.freeRules(self.allocator, rules);
        self.mutex.lock();
        defer self.mutex.unlock();
        self.entries.clearRetainingCapacity();
        for (rules) |rule| {
            try self.entries.append(self.allocator, .{ .rule = rule });
        }
    }

    pub fn markMissingProfileForTest(self: *Manager, index: usize) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (index >= self.entries.items.len) return false;
        self.entries.items[index].setStatus(.missing_profile, "profile missing");
        return false;
    }

    pub fn stopAll(self: *Manager) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.entries.items) |*entry| {
            entry.setStatus(.stopped, "");
        }
    }
};

fn copyBounded(dest: []u8, text: []const u8) usize {
    const n = @min(dest.len, text.len);
    @memcpy(dest[0..n], text[0..n]);
    return n;
}
```

- [ ] **Step 4: Run focused tests**

Run:

```bash
zig test src/port_forward_manager.zig
```

Expected: PASS.

- [ ] **Step 5: Add manager to fast suite**

In `src/test_fast.zig`, add this import after `ssh_profile_store.zig`:

```zig
    _ = @import("port_forward_manager.zig");
```

- [ ] **Step 6: Run the fast suite**

Run:

```bash
zig build test
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add src/port_forward_manager.zig src/test_fast.zig
git commit -m "feat(port-forward): add manager state"
```

---

### Task 4: OpenSSH Helper Argv, Spawn, Stop, And Tick

**Files:**
- Modify: `src/port_forward_manager.zig`
- Test: `src/port_forward_manager.zig`

- [ ] **Step 1: Add failing tests for argv and ControlMaster exclusion**

Append these tests to `src/port_forward_manager.zig`:

```zig
const ssh_connection = @import("ssh_connection.zig");

test "port_forward_manager: builds reverse ssh argv without connection sharing" {
    var conn: ssh_connection.SshConnection = .{};
    conn.user_len = copyBounded(conn.user_buf[0..], "alice");
    conn.host_len = copyBounded(conn.host_buf[0..], "example.test");
    conn.port_len = copyBounded(conn.port_buf[0..], "2222");
    conn.proxy_jump_len = copyBounded(conn.proxy_jump_buf[0..], "jump@example.test:22");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const rule = rule_mod.defaultReverseProxy("devbox");
    const argv = try buildSshArgvForTest(allocator, &rule, &conn);

    try std.testing.expectEqualStrings("ssh", argv[0]);
    try std.testing.expect(argvContainsForTest(argv, "-R"));
    try std.testing.expect(argvContainsForTest(argv, "127.0.0.1:7890:127.0.0.1:7890"));
    try std.testing.expect(argvContainsForTest(argv, "-p"));
    try std.testing.expect(argvContainsForTest(argv, "2222"));

    for (argv) |arg| {
        try std.testing.expect(std.mem.indexOf(u8, arg, "ControlMaster") == null);
        try std.testing.expect(std.mem.indexOf(u8, arg, "ControlPersist") == null);
        try std.testing.expect(std.mem.indexOf(u8, arg, "ControlPath") == null);
    }
}

test "port_forward_manager: running child exit becomes error" {
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    try manager.addRule(rule_mod.defaultReverseProxy("devbox"));

    try std.testing.expect(manager.markRunningForTest(0, 99));
    try std.testing.expect(manager.markExitedForTest(0, "ssh exited"));
    const row = manager.rowAt(0).?;
    try std.testing.expectEqual(StatusKind.error_, row.status);
    try std.testing.expectEqualStrings("ssh exited", row.reason);
}

fn argvContainsForTest(argv: []const []const u8, needle: []const u8) bool {
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, needle)) return true;
    }
    return false;
}
```

- [ ] **Step 2: Run the focused test to verify it fails**

Run:

```bash
zig test src/port_forward_manager.zig
```

Expected: FAIL with undefined identifiers such as `buildSshArgvForTest`, `markRunningForTest`, and `markExitedForTest`.

- [ ] **Step 3: Add process-facing imports and child state**

At the top of `src/port_forward_manager.zig`, add:

```zig
const builtin = @import("builtin");
const platform_process = @import("platform/process.zig");
const platform_pty_command = @import("platform/pty_command.zig");
const ssh_profile_store = @import("ssh_profile_store.zig");
const ssh_error = @import("ssh_error.zig");
```

Extend `Entry` with child state:

```zig
    child: ?std.process.Child = null,
    fake_pid_for_test: ?u32 = null,
```

- [ ] **Step 4: Add argv construction helpers**

Add these helpers below `Manager`:

```zig
const MAX_TUNNEL_SPEC_BYTES: usize = 160;
const MAX_SSH_DEST_BYTES: usize = 280;

pub fn buildSshArgvForTest(allocator: std.mem.Allocator, rule: *const rule_mod.Rule, conn: *const ssh_connection.SshConnection) ![][]const u8 {
    return buildSshArgv(allocator, rule, conn);
}

fn buildSshArgv(allocator: std.mem.Allocator, rule: *const rule_mod.Rule, conn: *const ssh_connection.SshConnection) ![][]const u8 {
    var spec_buf: [MAX_TUNNEL_SPEC_BYTES]u8 = undefined;
    const spec = rule.forwardSpec(&spec_buf) orelse return error.InvalidRule;
    var dest_buf: [MAX_SSH_DEST_BYTES]u8 = undefined;
    const dest = sshDestination(&dest_buf, conn) orelse return error.InvalidProfile;

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer argv.deinit(allocator);
    try argv.append(allocator, platform_pty_command.sshExecutableName());
    try argv.append(allocator, "-N");
    try argv.append(allocator, "-T");
    try argv.append(allocator, rule.direction.flag());
    try argv.append(allocator, try allocator.dupe(u8, spec));

    try appendSshOption(allocator, &argv, "ExitOnForwardFailure=yes");
    try appendSshOption(allocator, &argv, "StrictHostKeyChecking=accept-new");
    try appendSshOption(allocator, &argv, "ConnectTimeout=8");
    try appendSshOption(allocator, &argv, "ServerAliveInterval=60");
    try appendSshOption(allocator, &argv, "ServerAliveCountMax=3");
    if (conn.legacy_algorithms) {
        try appendSshOption(allocator, &argv, "HostkeyAlgorithms=+ssh-rsa,ssh-dss");
        try appendSshOption(allocator, &argv, "PubkeyAcceptedAlgorithms=+ssh-rsa,ssh-dss");
        try appendSshOption(allocator, &argv, "KexAlgorithms=+diffie-hellman-group14-sha1,diffie-hellman-group1-sha1");
        try appendSshOption(allocator, &argv, "Ciphers=+aes128-cbc,3des-cbc");
    }
    if (conn.password_auth) {
        try appendSshOption(allocator, &argv, "PreferredAuthentications=publickey,password,keyboard-interactive");
        try appendSshOption(allocator, &argv, "NumberOfPasswordPrompts=1");
    } else {
        try appendSshOption(allocator, &argv, "BatchMode=yes");
    }
    if (conn.proxyJump().len > 0) {
        try appendSshOption(allocator, &argv, try std.fmt.allocPrint(allocator, "ProxyJump={s}", .{conn.proxyJump()}));
    }
    if (conn.port().len > 0) {
        try argv.append(allocator, "-p");
        try argv.append(allocator, try allocator.dupe(u8, conn.port()));
    }
    try argv.append(allocator, try allocator.dupe(u8, dest));
    return argv.toOwnedSlice(allocator);
}

fn appendSshOption(allocator: std.mem.Allocator, argv: *std.ArrayListUnmanaged([]const u8), option: []const u8) !void {
    try argv.append(allocator, "-o");
    try argv.append(allocator, option);
}

fn sshDestination(buf: *[MAX_SSH_DEST_BYTES]u8, conn: *const ssh_connection.SshConnection) ?[]const u8 {
    const user = conn.user();
    const host = conn.host();
    const len = user.len + 1 + host.len;
    if (user.len == 0 or host.len == 0 or len > buf.len) return null;
    @memcpy(buf[0..user.len], user);
    buf[user.len] = '@';
    @memcpy(buf[user.len + 1 ..][0..host.len], host);
    return buf[0..len];
}
```

- [ ] **Step 5: Add start/stop/tick methods**

Add these methods inside `Manager`:

```zig
    pub fn startIndex(self: *Manager, index: usize, legacy_algorithms: bool) bool {
        self.mutex.lock();
        if (index >= self.entries.items.len) {
            self.mutex.unlock();
            return false;
        }
        const rule = self.entries.items[index].rule;
        self.entries.items[index].setStatus(.starting, "");
        self.mutex.unlock();

        const conn = ssh_profile_store.connectionByName(self.allocator, rule.profileName(), legacy_algorithms) orelse {
            self.mutex.lock();
            if (index < self.entries.items.len) self.entries.items[index].setStatus(.missing_profile, "profile missing");
            self.mutex.unlock();
            return false;
        };

        const child = spawnForward(self.allocator, &rule, &conn) catch |err| {
            var buf: [REASON_MAX]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "spawn failed: {}", .{err}) catch "spawn failed";
            self.mutex.lock();
            if (index < self.entries.items.len) self.entries.items[index].setStatus(.error_, msg);
            self.mutex.unlock();
            return false;
        };

        self.mutex.lock();
        if (index < self.entries.items.len) {
            self.entries.items[index].child = child;
            self.entries.items[index].setStatus(.running, "");
        }
        self.mutex.unlock();
        return true;
    }

    pub fn stopIndex(self: *Manager, index: usize) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (index >= self.entries.items.len) return false;
        stopEntry(&self.entries.items[index]);
        self.entries.items[index].setStatus(.stopped, "");
        return true;
    }

    pub fn restartIndex(self: *Manager, index: usize, legacy_algorithms: bool) bool {
        _ = self.stopIndex(index);
        return self.startIndex(index, legacy_algorithms);
    }

    pub fn startAuto(self: *Manager, legacy_algorithms: bool) void {
        var i: usize = 0;
        while (true) : (i += 1) {
            self.mutex.lock();
            const done = i >= self.entries.items.len;
            const should_start = !done and self.entries.items[i].rule.enabled and self.entries.items[i].rule.auto_start;
            self.mutex.unlock();
            if (done) break;
            if (should_start) _ = self.startIndex(i, legacy_algorithms);
        }
    }

    pub fn tick(self: *Manager) bool {
        var changed = false;
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.entries.items) |*entry| {
            if (entry.child) |*child| {
                if (childHasExited(child)) {
                    stopEntry(entry);
                    entry.setStatus(.error_, "ssh exited");
                    changed = true;
                }
            }
        }
        return changed;
    }

    pub fn markRunningForTest(self: *Manager, index: usize, pid: u32) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (index >= self.entries.items.len) return false;
        self.entries.items[index].fake_pid_for_test = pid;
        self.entries.items[index].setStatus(.running, "");
        return true;
    }

    pub fn markExitedForTest(self: *Manager, index: usize, reason: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (index >= self.entries.items.len) return false;
        self.entries.items[index].fake_pid_for_test = null;
        self.entries.items[index].setStatus(.error_, reason);
        return true;
    }
```

Add these helpers outside `Manager`:

```zig
fn spawnForward(allocator: std.mem.Allocator, rule: *const rule_mod.Rule, conn: *const ssh_connection.SshConnection) !std.process.Child {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const argv = try buildSshArgv(arena.allocator(), rule, conn);

    var askpass_path: ?[]const u8 = null;
    defer if (askpass_path) |path| allocator.free(path);
    var env_map: ?std.process.EnvMap = null;
    defer if (env_map) |*map| map.deinit();

    if (conn.password_auth) {
        askpass_path = platform_process.ensureSshAskPassScript(allocator) orelse return error.AskPassUnavailable;
        env_map = try std.process.getEnvMap(allocator);
        try platform_process.putSshAskPassEnv(&env_map.?, askpass_path.?, conn.password());
    }

    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Inherit;
    if (env_map) |*map| child.env_map = map;
    try child.spawn();
    return child;
}

fn stopEntry(entry: *Entry) void {
    if (entry.child) |*child| {
        if (childHasExited(child)) {
            if (builtin.os.tag != .windows) child.term = .{ .Unknown = 0 };
            _ = child.wait() catch {};
        } else {
            _ = child.kill() catch {};
        }
        entry.child = null;
    }
    entry.fake_pid_for_test = null;
}

fn childHasExited(child: *const std.process.Child) bool {
    return switch (platform_process.childExited(child.id, 0)) {
        .running => false,
        .exited, .gone => true,
    };
}
```

Change `Manager.stopAll` so it calls `stopEntry(entry)` before setting stopped.

- [ ] **Step 6: Run focused tests**

Run:

```bash
zig test src/port_forward_manager.zig
```

Expected: PASS.

- [ ] **Step 7: Run the fast suite**

Run:

```bash
zig build test
```

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add src/port_forward_manager.zig
git commit -m "feat(port-forward): manage ssh helper processes"
```

---

### Task 5: Port Forwarding Panel Model

**Files:**
- Create: `src/port_forwarding.zig`
- Modify: `src/test_fast.zig`
- Test: `src/port_forwarding.zig`

- [ ] **Step 1: Create failing panel-model tests**

Create `src/port_forwarding.zig` with:

```zig
const std = @import("std");
const rule_mod = @import("port_forward_rule.zig");

test "port_forwarding: selection clamps to row count" {
    var session = try Session.create(std.testing.allocator);
    defer session.destroy();
    session.model.move(1, 0);
    try std.testing.expectEqual(@as(usize, 0), session.model.sel_row);
    session.model.move(1, 3);
    try std.testing.expectEqual(@as(usize, 1), session.model.sel_row);
    session.model.move(99, 3);
    try std.testing.expectEqual(@as(usize, 2), session.model.sel_row);
    session.model.move(-99, 3);
    try std.testing.expectEqual(@as(usize, 0), session.model.sel_row);
}

test "port_forwarding: new form defaults to reverse proxy" {
    var session = try Session.create(std.testing.allocator);
    defer session.destroy();
    try session.model.openNewForm("devbox");
    const form = session.model.form() orelse return error.ExpectedForm;
    try std.testing.expectEqual(FormMode.new, form.mode);
    try std.testing.expectEqual(rule_mod.Direction.reverse, form.rule.direction);
    try std.testing.expectEqualStrings("devbox", form.rule.profileName());
}

test "port_forwarding: delete confirmation records selected index" {
    var session = try Session.create(std.testing.allocator);
    defer session.destroy();
    try session.model.openDeleteConfirm(2, "Local proxy");
    const confirm = session.model.confirm() orelse return error.ExpectedConfirm;
    try std.testing.expectEqual(@as(usize, 2), confirm.index);
    try std.testing.expectEqualStrings("Delete Local proxy? Enter confirms, Esc cancels.", confirm.text);
}
```

- [ ] **Step 2: Run the focused test to verify it fails**

Run:

```bash
zig test src/port_forwarding.zig
```

Expected: FAIL with undefined identifiers such as `Session`, `FormMode`, and `PanelModel`.

- [ ] **Step 3: Implement panel/session model**

Add this implementation above the tests:

```zig
pub const FormMode = enum { new, edit };
pub const FORM_FIELD_COUNT: usize = 8;

pub const FormState = struct {
    mode: FormMode,
    edit_index: ?usize,
    focus: usize = 0,
    rule: rule_mod.Rule,

    pub fn moveFocus(self: *FormState, delta: isize) void {
        const cur: isize = @intCast(self.focus);
        self.focus = @intCast(std.math.clamp(cur + delta, 0, @as(isize, FORM_FIELD_COUNT - 1)));
    }

    pub fn insertChar(self: *FormState, codepoint: u21) void {
        if (codepoint > 0x7f) return;
        const ch: u8 = @intCast(codepoint);
        switch (self.focus) {
            0 => appendAscii(&self.rule.name_buf, &self.rule.name_len, ch),
            1 => appendAscii(&self.rule.profile_buf, &self.rule.profile_len, ch),
            3 => appendAscii(&self.rule.local_host_buf, &self.rule.local_host_len, ch),
            4 => self.rule.local_port = appendPortDigit(self.rule.local_port, ch),
            5 => appendAscii(&self.rule.remote_host_buf, &self.rule.remote_host_len, ch),
            6 => self.rule.remote_port = appendPortDigit(self.rule.remote_port, ch),
            else => {},
        }
    }

    pub fn backspace(self: *FormState) void {
        switch (self.focus) {
            0 => if (self.rule.name_len > 0) self.rule.name_len -= 1,
            1 => if (self.rule.profile_len > 0) self.rule.profile_len -= 1,
            3 => if (self.rule.local_host_len > 0) self.rule.local_host_len -= 1,
            4 => self.rule.local_port /= 10,
            5 => if (self.rule.remote_host_len > 0) self.rule.remote_host_len -= 1,
            6 => self.rule.remote_port /= 10,
            else => {},
        }
    }

    pub fn toggleFocused(self: *FormState) void {
        switch (self.focus) {
            2 => self.rule.direction = if (self.rule.direction == .reverse) .local else .reverse,
            7 => self.rule.auto_start = !self.rule.auto_start,
            else => {},
        }
    }
};

pub const ConfirmState = struct {
    index: usize,
    text: []u8,

    fn deinit(self: *ConfirmState, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.* = undefined;
    }
};

pub const Overlay = union(enum) {
    none,
    form: FormState,
    confirm_delete: ConfirmState,

    fn deinit(self: *Overlay, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .none, .form => {},
            .confirm_delete => |*c| c.deinit(allocator),
        }
        self.* = .none;
    }
};

pub const PanelModel = struct {
    allocator: std.mem.Allocator,
    sel_row: usize = 0,
    scroll: usize = 0,
    overlay: Overlay = .none,

    pub fn init(allocator: std.mem.Allocator) PanelModel {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *PanelModel) void {
        self.overlay.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn move(self: *PanelModel, delta: isize, row_count: usize) void {
        if (row_count == 0) {
            self.sel_row = 0;
            return;
        }
        const cur: isize = @intCast(self.sel_row);
        self.sel_row = @intCast(std.math.clamp(cur + delta, 0, @as(isize, @intCast(row_count - 1))));
    }

    pub fn clearOverlay(self: *PanelModel) void {
        self.overlay.deinit(self.allocator);
    }

    pub fn openNewForm(self: *PanelModel, profile_name: []const u8) !void {
        self.clearOverlay();
        self.overlay = .{ .form = .{
            .mode = .new,
            .edit_index = null,
            .rule = rule_mod.defaultReverseProxy(profile_name),
        } };
    }

    pub fn openEditForm(self: *PanelModel, index: usize, rule: rule_mod.Rule) void {
        self.clearOverlay();
        self.overlay = .{ .form = .{
            .mode = .edit,
            .edit_index = index,
            .rule = rule,
        } };
    }

    pub fn openDeleteConfirm(self: *PanelModel, index: usize, label: []const u8) !void {
        self.clearOverlay();
        const text = try std.fmt.allocPrint(self.allocator, "Delete {s}? Enter confirms, Esc cancels.", .{label});
        self.overlay = .{ .confirm_delete = .{ .index = index, .text = text } };
    }

    pub fn form(self: *PanelModel) ?*FormState {
        return switch (self.overlay) {
            .form => |*f| f,
            else => null,
        };
    }

    pub fn confirm(self: *PanelModel) ?*ConfirmState {
        return switch (self.overlay) {
            .confirm_delete => |*c| c,
            else => null,
        };
    }
};

pub const Session = struct {
    mutex: std.Thread.Mutex = .{},
    model: PanelModel,

    pub fn create(allocator: std.mem.Allocator) !*Session {
        const session = try allocator.create(Session);
        session.* = .{ .model = PanelModel.init(allocator) };
        return session;
    }

    pub fn destroy(self: *Session) void {
        const allocator = self.model.allocator;
        self.model.deinit();
        allocator.destroy(self);
    }
};

fn appendAscii(buf: *[64]u8, len: *usize, ch: u8) void {
    if (len.* >= buf.len) return;
    if (ch < 0x20 or ch > 0x7e) return;
    buf[len.*] = ch;
    len.* += 1;
}

fn appendPortDigit(port: u16, ch: u8) u16 {
    if (ch < '0' or ch > '9') return port;
    const next = @as(u32, port) * 10 + (ch - '0');
    if (next > std.math.maxInt(u16)) return port;
    return @intCast(next);
}
```

Adjust `appendAscii` to accept all three fixed buffer sizes by replacing it with:

```zig
fn appendAscii(buf: anytype, len: *usize, ch: u8) void {
    if (len.* >= buf.len) return;
    if (ch < 0x20 or ch > 0x7e) return;
    buf[len.*] = ch;
    len.* += 1;
}
```

- [ ] **Step 4: Run focused tests**

Run:

```bash
zig test src/port_forwarding.zig
```

Expected: PASS.

- [ ] **Step 5: Add module to fast suite**

In `src/test_fast.zig`, add:

```zig
    _ = @import("port_forwarding.zig");
```

after `port_forward_manager.zig`.

- [ ] **Step 6: Run the fast suite**

Run:

```bash
zig build test
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add src/port_forwarding.zig src/test_fast.zig
git commit -m "feat(port-forward): add panel model"
```

---

### Task 6: Port Forwarding Renderer

**Files:**
- Create: `src/renderer/port_forwarding_renderer.zig`
- Modify: `src/test_fast.zig`
- Test: `src/renderer/port_forwarding_renderer.zig`

- [ ] **Step 1: Create failing renderer-helper tests**

Create `src/renderer/port_forwarding_renderer.zig` with:

```zig
const std = @import("std");
const manager = @import("../port_forward_manager.zig");
const rule_mod = @import("../port_forward_rule.zig");

test "port_forwarding_renderer: status labels" {
    try std.testing.expectEqualStrings("Stopped", statusLabel(.stopped));
    try std.testing.expectEqualStrings("Starting", statusLabel(.starting));
    try std.testing.expectEqualStrings("Running", statusLabel(.running));
    try std.testing.expectEqualStrings("Error", statusLabel(.error_));
    try std.testing.expectEqualStrings("Missing", statusLabel(.missing_profile));
}

test "port_forwarding_renderer: listen and target labels" {
    var rule = rule_mod.defaultReverseProxy("devbox");
    var listen_buf: [96]u8 = undefined;
    var target_buf: [96]u8 = undefined;
    try std.testing.expectEqualStrings("remote 127.0.0.1:7890", listenLabel(&rule, &listen_buf));
    try std.testing.expectEqualStrings("local 127.0.0.1:7890", targetLabel(&rule, &target_buf));

    rule.direction = .local;
    rule.local_port = 8888;
    rule.remote_port = 8888;
    try std.testing.expectEqualStrings("local 127.0.0.1:8888", listenLabel(&rule, &listen_buf));
    try std.testing.expectEqualStrings("remote 127.0.0.1:8888", targetLabel(&rule, &target_buf));
}
```

- [ ] **Step 2: Run the focused test to verify it fails**

Run:

```bash
zig test src/renderer/port_forwarding_renderer.zig
```

Expected: FAIL with undefined identifiers such as `statusLabel`, `listenLabel`, and `targetLabel`.

- [ ] **Step 3: Implement renderer helpers and render API**

Add this implementation above the tests:

```zig
pub const Color = @Vector(3, f32);

pub const DrawContext = struct {
    bg: Color,
    fg: Color,
    accent: Color,
    cell_h: f32,
    fillQuad: *const fn (f32, f32, f32, f32, Color) void,
    fillQuadAlpha: *const fn (f32, f32, f32, f32, Color, f32) void,
    renderTextLimited: *const fn ([]const u8, f32, f32, Color, f32) f32,
    glyphAdvance: *const fn () f32,
};

pub const RowAt = *const fn (*anyopaque, usize) manager.RowView;

pub const View = struct {
    title: []const u8,
    legend: []const u8,
    row_count: usize,
    selected: usize,
    scroll: usize,
    ctx: *anyopaque,
    rowAt: RowAt,
    overlay_text: []const u8 = "",
};

pub fn statusLabel(status: manager.StatusKind) []const u8 {
    return switch (status) {
        .stopped => "Stopped",
        .starting => "Starting",
        .running => "Running",
        .error_ => "Error",
        .missing_profile => "Missing",
    };
}

pub fn directionLabel(direction: rule_mod.Direction) []const u8 {
    return switch (direction) {
        .local => "Local",
        .reverse => "Reverse",
    };
}

pub fn autoLabel(value: bool) []const u8 {
    return if (value) "On" else "Off";
}

pub fn listenLabel(rule: *const rule_mod.Rule, buf: []u8) []const u8 {
    return switch (rule.direction) {
        .local => std.fmt.bufPrint(buf, "local {s}:{d}", .{ rule.localHost(), rule.local_port }) catch "",
        .reverse => std.fmt.bufPrint(buf, "remote {s}:{d}", .{ rule.remoteHost(), rule.remote_port }) catch "",
    };
}

pub fn targetLabel(rule: *const rule_mod.Rule, buf: []u8) []const u8 {
    return switch (rule.direction) {
        .local => std.fmt.bufPrint(buf, "remote {s}:{d}", .{ rule.remoteHost(), rule.remote_port }) catch "",
        .reverse => std.fmt.bufPrint(buf, "local {s}:{d}", .{ rule.localHost(), rule.local_port }) catch "",
    };
}

pub fn bodyVisibleCapacity(height: f32, titlebar_offset: f32, cell_h: f32) usize {
    const body_h = height - titlebar_offset - cell_h * 5;
    if (body_h <= cell_h) return 1;
    return @max(1, @as(usize, @intFromFloat(@floor(body_h / cell_h))));
}

pub fn clampScroll(scroll: usize, selected: usize, visible: usize) usize {
    if (selected < scroll) return selected;
    if (visible == 0) return scroll;
    if (selected >= scroll + visible) return selected - visible + 1;
    return scroll;
}

pub fn render(draw: DrawContext, view: View, width: f32, height: f32, titlebar_offset: f32, left: f32, content_w: f32) void {
    const pad_x: f32 = 18;
    const x = left + pad_x;
    const y0 = titlebar_offset + draw.cell_h * 1.4;
    const title_end = draw.renderTextLimited(view.title, x, y0, draw.fg, content_w - pad_x * 2);
    _ = title_end;

    const header_y = y0 + draw.cell_h * 1.6;
    _ = draw.renderTextLimited("Status", x, header_y, draw.accent, 90);
    _ = draw.renderTextLimited("Dir", x + 95, header_y, draw.accent, 80);
    _ = draw.renderTextLimited("Profile", x + 180, header_y, draw.accent, 110);
    _ = draw.renderTextLimited("Listen", x + 295, header_y, draw.accent, 210);
    _ = draw.renderTextLimited("Target", x + 510, header_y, draw.accent, 210);
    _ = draw.renderTextLimited("Auto", x + 725, header_y, draw.accent, 55);
    _ = draw.renderTextLimited("Name", x + 785, header_y, draw.accent, content_w - 800);

    const visible = bodyVisibleCapacity(height, titlebar_offset, draw.cell_h);
    const scroll = clampScroll(view.scroll, view.selected, visible);
    var row: usize = 0;
    while (row < visible and row + scroll < view.row_count) : (row += 1) {
        const idx = row + scroll;
        const item = view.rowAt(view.ctx, idx);
        const row_y = header_y + draw.cell_h * @as(f32, @floatFromInt(row + 1));
        if (idx == view.selected) {
            draw.fillQuadAlpha(x - 8, row_y - draw.cell_h + 3, content_w - pad_x * 2, draw.cell_h, draw.accent, 0.18);
        }
        var listen_buf: [96]u8 = undefined;
        var target_buf: [96]u8 = undefined;
        _ = draw.renderTextLimited(statusLabel(item.status), x, row_y, draw.fg, 90);
        _ = draw.renderTextLimited(directionLabel(item.rule.direction), x + 95, row_y, draw.fg, 80);
        _ = draw.renderTextLimited(item.rule.profileName(), x + 180, row_y, draw.fg, 110);
        _ = draw.renderTextLimited(listenLabel(&item.rule, &listen_buf), x + 295, row_y, draw.fg, 210);
        _ = draw.renderTextLimited(targetLabel(&item.rule, &target_buf), x + 510, row_y, draw.fg, 210);
        _ = draw.renderTextLimited(autoLabel(item.auto_start), x + 725, row_y, draw.fg, 55);
        const display_name = if (item.rule.name().len > 0) item.rule.name() else item.reason;
        _ = draw.renderTextLimited(display_name, x + 785, row_y, draw.fg, content_w - 800);
    }

    const legend_y = height - draw.cell_h * 1.2;
    _ = draw.renderTextLimited(view.legend, x, legend_y, draw.fg, content_w - pad_x * 2);
    if (view.overlay_text.len > 0) {
        const box_w = @min(content_w - 80, 720);
        const box_h = draw.cell_h * 3.0;
        const box_x = left + (content_w - box_w) / 2;
        const box_y = titlebar_offset + (height - titlebar_offset - box_h) / 2;
        draw.fillQuadAlpha(box_x, box_y, box_w, box_h, draw.bg, 0.92);
        draw.fillQuadAlpha(box_x, box_y, box_w, box_h, draw.accent, 0.20);
        _ = draw.renderTextLimited(view.overlay_text, box_x + 18, box_y + draw.cell_h * 1.8, draw.fg, box_w - 36);
    }
}
```

- [ ] **Step 4: Run focused tests**

Run:

```bash
zig test src/renderer/port_forwarding_renderer.zig
```

Expected: PASS.

- [ ] **Step 5: Add renderer to fast suite**

In `src/test_fast.zig`, add:

```zig
    _ = @import("renderer/port_forwarding_renderer.zig");
```

after the Skill Center renderer import.

- [ ] **Step 6: Run the fast suite**

Run:

```bash
zig build test
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add src/renderer/port_forwarding_renderer.zig src/test_fast.zig
git commit -m "feat(port-forward): add management renderer"
```

---

### Task 7: App-Owned Manager Lifecycle

**Files:**
- Modify: `src/port_forward_manager.zig`
- Modify: `src/App.zig`
- Test: `src/port_forward_manager.zig`

- [ ] **Step 1: Add failing tests for load/save path helpers**

Append to `src/port_forward_manager.zig`:

```zig
test "port_forward_manager: save and load from explicit path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath(".", &dir_buf);
    const path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "rules.txt" });
    defer std.testing.allocator.free(path);

    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    manager.setStoragePathForTest(path);
    try manager.addRule(rule_mod.defaultReverseProxy("devbox"));
    try std.testing.expect(manager.save());

    var loaded = Manager.init(std.testing.allocator);
    defer loaded.deinit();
    loaded.setStoragePathForTest(path);
    try std.testing.expect(loaded.load());
    try std.testing.expectEqual(@as(usize, 1), loaded.count());
}
```

- [ ] **Step 2: Run focused test to verify it fails**

Run:

```bash
zig test src/port_forward_manager.zig
```

Expected: FAIL with undefined methods `setStoragePathForTest`, `save`, and `load`.

- [ ] **Step 3: Add storage path support**

Add to `Manager` fields:

```zig
    storage_path: ?[]u8 = null,
```

Update `deinit`:

```zig
        if (self.storage_path) |p| self.allocator.free(p);
```

Add methods:

```zig
    pub fn setStoragePath(self: *Manager, path: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.storage_path) |old| self.allocator.free(old);
        self.storage_path = try self.allocator.dupe(u8, path);
    }

    pub fn setStoragePathForTest(self: *Manager, path: []const u8) void {
        self.setStoragePath(path) catch unreachable;
    }

    pub fn load(self: *Manager) !bool {
        const path = self.storage_path orelse return false;
        const content = std.fs.cwd().readFileAlloc(self.allocator, path, 1024 * 1024) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        defer self.allocator.free(content);
        try self.loadFromContent(content);
        return true;
    }

    pub fn save(self: *Manager) bool {
        const path = self.storage_path orelse return false;
        if (std.fs.path.dirname(path)) |dir| {
            std.fs.cwd().makePath(dir) catch return false;
        }
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(self.allocator);
        self.encode(self.allocator, &out) catch return false;
        const file = std.fs.cwd().createFile(path, .{ .truncate = true }) catch return false;
        defer file.close();
        file.writeAll(out.items) catch return false;
        return true;
    }
```

- [ ] **Step 4: Run manager tests**

Run:

```bash
zig test src/port_forward_manager.zig
```

Expected: PASS.

- [ ] **Step 5: Wire manager into App**

In `src/App.zig`, add imports:

```zig
const port_forward_manager = @import("port_forward_manager.zig");
```

Add field after `weixin_controller`:

```zig
port_forward_manager: port_forward_manager.Manager,
```

In `App.init`, before `var app = App{`, create and load the manager:

```zig
    var forward_manager = port_forward_manager.Manager.init(allocator);
    errdefer forward_manager.deinit();
    if (platform_dirs.pathInConfigDir(allocator, "port_forwards")) |forward_path| {
        defer allocator.free(forward_path);
        forward_manager.setStoragePath(forward_path) catch {};
        _ = forward_manager.load() catch |err| blk: {
            std.debug.print("Port forwarding rules not loaded: {}\n", .{err});
            break :blk false;
        };
        forward_manager.startAuto(cfg.@"ssh-legacy-algorithms");
    } else |err| {
        std.debug.print("Port forwarding storage unavailable: {}\n", .{err});
    }
```

Add the field in the `App{}` literal:

```zig
        .port_forward_manager = forward_manager,
```

In `App.deinit`, before freeing owned strings:

```zig
    self.port_forward_manager.deinit();
```

- [ ] **Step 6: Run the fast suite**

Run:

```bash
zig build test
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add src/port_forward_manager.zig src/App.zig
git commit -m "feat(port-forward): load app-level rules"
```

---

### Task 8: Tab Kind, AppWindow Rendering, And Manager Actions

**Files:**
- Modify: `src/appwindow/tab.zig`
- Modify: `src/AppWindow.zig`
- Modify: `src/test_main.zig`
- Test: `zig build test-full`

- [ ] **Step 1: Add imports and tab fields**

In `src/appwindow/tab.zig`, add:

```zig
const port_forwarding = @import("../port_forwarding.zig");
```

Add field to `TabState`:

```zig
    port_forwarding_session: ?*port_forwarding.Session = null,
```

Add enum value:

```zig
        port_forwarding,
```

Update `getTitle`:

```zig
        if (self.kind == .port_forwarding) {
            return i18n.s().pf_title;
        }
```

Update `deinit` switch:

```zig
            .port_forwarding => {
                if (self.port_forwarding_session) |session| {
                    session.destroy();
                    self.port_forwarding_session = null;
                }
            },
```

Set `port_forwarding_session = null` in existing tab constructors, and set other session pointers to null in the new constructor below.

- [ ] **Step 2: Add tab spawn/accessor functions**

Add after `spawnSkillCenterTab`:

```zig
pub fn spawnPortForwardingTab(allocator: std.mem.Allocator) bool {
    if (g_tab_count >= MAX_TABS) return false;
    const session_ptr = port_forwarding.Session.create(allocator) catch return false;

    const t = allocator.create(TabState) catch {
        session_ptr.destroy();
        return false;
    };
    t.kind = .port_forwarding;
    t.tree = .empty;
    t.focused = .root;
    t.ai_chat_session = null;
    t.ai_history_session = null;
    t.skill_center_session = null;
    t.port_forwarding_session = session_ptr;
    t.copilot_session = null;
    t.copilot_visible = false;

    g_tabs[g_tab_count] = t;
    active_tab_state.g_active_tab = g_tab_count;
    g_tab_count += 1;
    return true;
}

pub fn activePortForwarding() ?*port_forwarding.Session {
    const t = activeTab() orelse return null;
    if (t.kind != .port_forwarding) return null;
    return t.port_forwarding_session;
}
```

Update `applyRestoredTabMetadata` switch with `.port_forwarding => {}`.

- [ ] **Step 3: Wire AppWindow imports and active helper**

In `src/AppWindow.zig`, add imports near Skill Center:

```zig
pub const port_forwarding = @import("port_forwarding.zig");
pub const port_forwarding_renderer = @import("renderer/port_forwarding_renderer.zig");
```

Add:

```zig
pub fn activePortForwarding() ?*port_forwarding.Session {
    return tab.activePortForwarding();
}
```

- [ ] **Step 4: Add renderer callback and frame renderer**

Add near Skill Center renderer helpers:

```zig
fn pfRowAt(ctx: *anyopaque, i: usize) port_forward_manager.RowView {
    const manager: *port_forward_manager.Manager = @ptrCast(@alignCast(ctx));
    return manager.rowAt(i) orelse .{
        .rule = port_forward_rule.defaultReverseProxy(""),
        .status = .stopped,
        .reason = "",
        .auto_start = false,
    };
}

fn renderPortForwardingFrame(active_tab: *TabState, fb_width: c_int, fb_height: c_int, titlebar_offset: f32, left_panels_w: f32, right_panels_w: f32) void {
    gpu.state.setViewport(0, 0, @intCast(fb_width), @intCast(fb_height));
    gpu.gl_init.setProjection(@floatFromInt(fb_width), @floatFromInt(fb_height));
    clearWithBackground(fb_width, fb_height);
    titlebar.renderTitlebar(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
    titlebar.renderSidebar(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
    markdown_preview_renderer.render(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset, 0);
    file_explorer_renderer.render(@floatFromInt(fb_width), @floatFromInt(fb_height), titlebar_offset);
    const session = active_tab.port_forwarding_session orelse return;
    const app = g_app orelse return;

    session.mutex.lock();
    defer session.mutex.unlock();
    const row_count = app.port_forward_manager.count();
    session.model.move(0, row_count);
    const draw: port_forwarding_renderer.DrawContext = .{
        .bg = g_theme.background,
        .fg = g_theme.foreground,
        .accent = g_theme.cursor_color,
        .cell_h = font.g_titlebar_cell_height,
        .fillQuad = ui_pipeline.fillQuad,
        .fillQuadAlpha = ui_pipeline.fillQuadAlpha,
        .renderTextLimited = titlebar.renderTextLimited,
        .glyphAdvance = titlebar.titlebarGlyphAdvance,
    };
    const overlay_text = switch (session.model.overlay) {
        .none, .form => "",
        .confirm_delete => |*c| c.text,
    };
    const view: port_forwarding_renderer.View = .{
        .title = i18n.s().pf_title,
        .legend = i18n.s().pf_legend,
        .row_count = row_count,
        .selected = session.model.sel_row,
        .scroll = session.model.scroll,
        .ctx = @ptrCast(&app.port_forward_manager),
        .rowAt = pfRowAt,
        .overlay_text = overlay_text,
    };
    port_forwarding_renderer.render(
        draw,
        view,
        @floatFromInt(fb_width),
        @floatFromInt(fb_height),
        titlebar_offset,
        left_panels_w,
        aiHistoryContentWidth(fb_width, left_panels_w, right_panels_w),
    );
}
```

Add missing imports:

```zig
const port_forward_manager = @import("port_forward_manager.zig");
const port_forward_rule = @import("port_forward_rule.zig");
```

- [ ] **Step 5: Add AppWindow spawn and action wrappers**

Add near `spawnSkillCenterTab`:

```zig
pub fn spawnPortForwardingTab() bool {
    const allocator = g_allocator orelse return false;
    if (!tab.spawnPortForwardingTab(allocator)) return false;
    clearUiStateOnTabChange();
    markUiDirty();
    return true;
}

fn activePortForwardManager() ?*port_forward_manager.Manager {
    const app = g_app orelse return null;
    return &app.port_forward_manager;
}

pub fn portForwardingMove(delta: isize) bool {
    const session = activePortForwarding() orelse return false;
    const manager = activePortForwardManager() orelse return false;
    session.mutex.lock();
    defer session.mutex.unlock();
    session.model.move(delta, manager.count());
    markUiDirty();
    return true;
}

pub fn portForwardingToggleSelected() bool {
    const session = activePortForwarding() orelse return false;
    const manager = activePortForwardManager() orelse return false;
    const app = g_app orelse return false;
    session.mutex.lock();
    const idx = session.model.sel_row;
    session.mutex.unlock();
    const row = manager.rowAt(idx) orelse return false;
    const ok = switch (row.status) {
        .running, .starting => manager.stopIndex(idx),
        else => manager.startIndex(idx, app.ssh_legacy_algorithms),
    };
    markUiDirty();
    return ok;
}

pub fn portForwardingRestartSelected() bool {
    const session = activePortForwarding() orelse return false;
    const manager = activePortForwardManager() orelse return false;
    const app = g_app orelse return false;
    session.mutex.lock();
    const idx = session.model.sel_row;
    session.mutex.unlock();
    const ok = manager.restartIndex(idx, app.ssh_legacy_algorithms);
    markUiDirty();
    return ok;
}

pub fn portForwardingToggleAutoStart() bool {
    const session = activePortForwarding() orelse return false;
    const manager = activePortForwardManager() orelse return false;
    session.mutex.lock();
    const idx = session.model.sel_row;
    session.mutex.unlock();
    const ok = manager.toggleAutoStart(idx);
    if (ok) _ = manager.save();
    markUiDirty();
    return ok;
}
```

- [ ] **Step 6: Render the new tab kind and tick manager**

In both render switch locations that currently handle `.skill_center`, add:

```zig
            } else if (active_tab.kind == .port_forwarding) {
                renderPortForwardingFrame(active_tab, fb_width, fb_height, titlebar_offset, left_panels_w, right_panels_w);
```

In the main loop near `pollSkillCenterOp`, add:

```zig
        if (self.app.port_forward_manager.tick()) {
            if (activePortForwarding() != null) {
                g_force_rebuild = true;
                g_cells_valid = false;
            }
        }
```

- [ ] **Step 7: Import new modules in test_main**

In `src/test_main.zig`, add near Skill Center imports:

```zig
    _ = @import("port_forward_rule.zig");
    _ = @import("ssh_profile_store.zig");
    _ = @import("port_forward_manager.zig");
    _ = @import("port_forwarding.zig");
    _ = @import("renderer/port_forwarding_renderer.zig");
```

- [ ] **Step 8: Run full compile gate**

Run:

```bash
zig build test-full
```

Expected: PASS. If the first run reports missing `TabState` field initializers, set `port_forwarding_session = null` in every existing `TabState` constructor, rerun `zig build test-full`, and proceed only after PASS.

- [ ] **Step 9: Commit**

```bash
git add src/appwindow/tab.zig src/AppWindow.zig src/test_main.zig
git commit -m "feat(port-forward): add management tab"
```

---

### Task 9: Command Center, I18n, And Input Routing

**Files:**
- Modify: `src/command_center_state.zig`
- Modify: `src/i18n.zig`
- Modify: `src/renderer/overlays.zig`
- Modify: `src/input.zig`
- Test: `src/command_center_state.zig`, `src/input.zig`, `zig build test-full`

- [ ] **Step 1: Add failing command-center test**

In `src/command_center_state.zig`, add enum value:

```zig
    open_port_forwarding,
```

Add command entry before Skill Center:

```zig
    .{ .title = "Port Forwarding", .detail = "Manage SSH port forwarding rules", .shortcut = "", .action = .open_port_forwarding },
```

Add test near the Skill Center test:

```zig
test "command center includes Port Forwarding action" {
    try std.testing.expectEqual(CommandAction.open_port_forwarding, findCommandAction("Port Forwarding"));
}
```

Run:

```bash
zig test src/command_center_state.zig
```

Expected: PASS after the enum and entry are present.

- [ ] **Step 2: Add i18n fields**

In `src/i18n.zig` `Strings`, add:

```zig
    pf_title: []const u8,
    pf_detail: []const u8,
    pf_legend: []const u8,
```

In English strings, add:

```zig
    .pf_title = "Port Forwarding",
    .pf_detail = "Manage SSH port forwarding rules",
    .pf_legend = "[n] new   [e] edit   [space] start/stop   [r] restart   [a] auto   [d] delete   [esc] close/cancel",
```

In Chinese strings, add:

```zig
    .pf_title = "端口转发",
    .pf_detail = "管理 SSH 端口转发规则",
    .pf_legend = "[n] 新建   [e] 编辑   [space] 启停   [r] 重启   [a] 自动启动   [d] 删除   [esc] 关闭/取消",
```

In `commandTitle`, add:

```zig
        .open_port_forwarding => "端口转发",
```

In `commandDetail`, add:

```zig
        .open_port_forwarding => "管理 SSH 端口转发规则",
```

- [ ] **Step 3: Wire command execution**

In `src/renderer/overlays.zig` `executeCommand`, add:

```zig
        .open_port_forwarding => {
            _ = AppWindow.spawnPortForwardingTab();
        },
```

- [ ] **Step 4: Add input routing**

In `src/input.zig` `handleChar`, before the Skill Center branch, add:

```zig
    if (AppWindow.activePortForwarding() != null) {
        if (!ev.ctrl and !ev.alt and !ev.super) {
            _ = AppWindow.portForwardingInsertChar(ev.codepoint);
        }
        return;
    }
```

In `handleKey`, before the Skill Center branch, add:

```zig
    if (AppWindow.activePortForwarding() != null) {
        const plain = !ev.ctrl and !ev.alt and !ev.super;
        switch (ev.key_code) {
            platform_input.key_up => {
                _ = AppWindow.portForwardingMove(-1);
                return;
            },
            platform_input.key_down => {
                _ = AppWindow.portForwardingMove(1);
                return;
            },
            platform_input.key_tab => {
                _ = AppWindow.portForwardingFormMove(1);
                return;
            },
            platform_input.key_enter => {
                _ = AppWindow.portForwardingConfirmOrApply();
                return;
            },
            platform_input.key_escape => {
                _ = AppWindow.portForwardingCancelOrClose();
                return;
            },
            platform_input.key_backspace => {
                _ = AppWindow.portForwardingBackspace();
                return;
            },
            platform_input.key_space => if (plain and !ev.shift) {
                if (AppWindow.portForwardingFormToggle()) return;
                _ = AppWindow.portForwardingToggleSelected();
                return;
            },
            0x4E => if (plain and !ev.shift) {
                _ = AppWindow.portForwardingOpenNew();
                return;
            },
            0x45 => if (plain and !ev.shift) {
                _ = AppWindow.portForwardingOpenEdit();
                return;
            },
            0x44 => if (plain and !ev.shift) {
                _ = AppWindow.portForwardingOpenDeleteConfirm();
                return;
            },
            0x52 => if (plain and !ev.shift) {
                _ = AppWindow.portForwardingRestartSelected();
                return;
            },
            0x41 => if (plain and !ev.shift) {
                _ = AppWindow.portForwardingToggleAutoStart();
                return;
            },
            else => {},
        }
        return;
    }
```

- [ ] **Step 5: Add AppWindow form/delete wrappers**

In `src/AppWindow.zig`, add:

```zig
pub fn portForwardingOpenNew() bool {
    const session = activePortForwarding() orelse return false;
    session.mutex.lock();
    defer session.mutex.unlock();
    session.model.openNewForm("") catch return false;
    markUiDirty();
    return true;
}

pub fn portForwardingOpenEdit() bool {
    const session = activePortForwarding() orelse return false;
    const manager = activePortForwardManager() orelse return false;
    session.mutex.lock();
    const idx = session.model.sel_row;
    session.mutex.unlock();
    const row = manager.rowAt(idx) orelse return false;
    session.mutex.lock();
    defer session.mutex.unlock();
    session.model.openEditForm(idx, row.rule);
    markUiDirty();
    return true;
}

pub fn portForwardingOpenDeleteConfirm() bool {
    const session = activePortForwarding() orelse return false;
    const manager = activePortForwardManager() orelse return false;
    session.mutex.lock();
    const idx = session.model.sel_row;
    session.mutex.unlock();
    const row = manager.rowAt(idx) orelse return false;
    const label = if (row.rule.name().len > 0) row.rule.name() else row.rule.profileName();
    session.mutex.lock();
    defer session.mutex.unlock();
    session.model.openDeleteConfirm(idx, label) catch return false;
    markUiDirty();
    return true;
}

pub fn portForwardingConfirmOrApply() bool {
    const session = activePortForwarding() orelse return false;
    const manager = activePortForwardManager() orelse return false;
    session.mutex.lock();
    defer session.mutex.unlock();
    switch (session.model.overlay) {
        .form => |form| {
            if (!form.rule.validate()) return false;
            const ok = switch (form.mode) {
                .new => blk: {
                    manager.addRule(form.rule) catch break :blk false;
                    break :blk true;
                },
                .edit => if (form.edit_index) |idx| manager.updateRule(idx, form.rule) else false,
            };
            if (ok) {
                _ = manager.save();
                session.model.clearOverlay();
                markUiDirty();
            }
            return ok;
        },
        .confirm_delete => |confirm| {
            const ok = manager.deleteRule(confirm.index);
            if (ok) {
                _ = manager.save();
                session.model.clearOverlay();
                session.model.move(0, manager.count());
                markUiDirty();
            }
            return ok;
        },
        .none => return false,
    }
}

pub fn portForwardingCancelOrClose() bool {
    const session = activePortForwarding() orelse return false;
    session.mutex.lock();
    const had_overlay = session.model.overlay != .none;
    if (had_overlay) session.model.clearOverlay();
    session.mutex.unlock();
    if (had_overlay) {
        markUiDirty();
        return true;
    }
    input.closePanelOrTab();
    return true;
}

pub fn portForwardingFormMove(delta: isize) bool {
    const session = activePortForwarding() orelse return false;
    session.mutex.lock();
    defer session.mutex.unlock();
    const form = session.model.form() orelse return false;
    form.moveFocus(delta);
    markUiDirty();
    return true;
}

pub fn portForwardingFormToggle() bool {
    const session = activePortForwarding() orelse return false;
    session.mutex.lock();
    defer session.mutex.unlock();
    const form = session.model.form() orelse return false;
    form.toggleFocused();
    markUiDirty();
    return true;
}

pub fn portForwardingInsertChar(codepoint: u21) bool {
    const session = activePortForwarding() orelse return false;
    session.mutex.lock();
    defer session.mutex.unlock();
    const form = session.model.form() orelse return false;
    form.insertChar(codepoint);
    markUiDirty();
    return true;
}

pub fn portForwardingBackspace() bool {
    const session = activePortForwarding() orelse return false;
    session.mutex.lock();
    defer session.mutex.unlock();
    const form = session.model.form() orelse return false;
    form.backspace();
    markUiDirty();
    return true;
}
```

- [ ] **Step 6: Add input dirty regression test**

In `src/input.zig`, add a full-app test near the Skill Center dirty tests:

```zig
test "input: port forwarding arrow navigation requests a repaint" {
    const allocator = std.testing.allocator;
    if (!tab.spawnPortForwardingTab(allocator)) return error.SkipZigTest;
    defer {
        if (tab.g_tab_count > 0) tab.closeTab(tab.g_tab_count - 1, allocator);
    }

    AppWindow.g_force_rebuild = false;
    AppWindow.g_cells_valid = true;
    const ev: platform_input.KeyEvent = .{ .key_code = platform_input.key_down };
    handleKey(ev);
    try std.testing.expect(AppWindow.g_force_rebuild);
    try std.testing.expect(!AppWindow.g_cells_valid);
}
```

- [ ] **Step 7: Run focused and full tests**

Run:

```bash
zig test src/command_center_state.zig
zig build test-full
```

Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add src/command_center_state.zig src/i18n.zig src/renderer/overlays.zig src/input.zig src/AppWindow.zig
git commit -m "feat(port-forward): wire command and input"
```

---

### Task 10: Form Rendering Details

**Files:**
- Modify: `src/renderer/port_forwarding_renderer.zig`
- Modify: `src/AppWindow.zig`
- Test: `src/renderer/port_forwarding_renderer.zig`

- [ ] **Step 1: Add failing form-label helper test**

Append:

```zig
test "port_forwarding_renderer: form field labels" {
    try std.testing.expectEqualStrings("Name", formFieldLabel(0));
    try std.testing.expectEqualStrings("Profile", formFieldLabel(1));
    try std.testing.expectEqualStrings("Direction", formFieldLabel(2));
    try std.testing.expectEqualStrings("Local host", formFieldLabel(3));
    try std.testing.expectEqualStrings("Local port", formFieldLabel(4));
    try std.testing.expectEqualStrings("Remote host", formFieldLabel(5));
    try std.testing.expectEqualStrings("Remote port", formFieldLabel(6));
    try std.testing.expectEqualStrings("Auto start", formFieldLabel(7));
    try std.testing.expectEqualStrings("", formFieldLabel(99));
}
```

- [ ] **Step 2: Run focused test to verify it fails**

Run:

```bash
zig test src/renderer/port_forwarding_renderer.zig
```

Expected: FAIL with undefined `formFieldLabel`.

- [ ] **Step 3: Add form renderer view data**

In `src/renderer/port_forwarding_renderer.zig`, add:

```zig
pub const FormView = struct {
    mode: []const u8,
    focus: usize,
    rule: rule_mod.Rule,
};

pub fn formFieldLabel(index: usize) []const u8 {
    return switch (index) {
        0 => "Name",
        1 => "Profile",
        2 => "Direction",
        3 => "Local host",
        4 => "Local port",
        5 => "Remote host",
        6 => "Remote port",
        7 => "Auto start",
        else => "",
    };
}

pub fn formFieldValue(form: FormView, index: usize, buf: []u8) []const u8 {
    return switch (index) {
        0 => form.rule.name(),
        1 => form.rule.profileName(),
        2 => directionLabel(form.rule.direction),
        3 => form.rule.localHost(),
        4 => std.fmt.bufPrint(buf, "{d}", .{form.rule.local_port}) catch "",
        5 => form.rule.remoteHost(),
        6 => std.fmt.bufPrint(buf, "{d}", .{form.rule.remote_port}) catch "",
        7 => autoLabel(form.rule.auto_start),
        else => "",
    };
}
```

Add optional `form: ?FormView = null` to `View`.

Inside `render`, after the confirmation overlay block, draw the form when present:

```zig
    if (view.form) |form| {
        const box_w = @min(content_w - 80, 720);
        const box_h = draw.cell_h * 11.0;
        const box_x = left + (content_w - box_w) / 2;
        const box_y = titlebar_offset + (height - titlebar_offset - box_h) / 2;
        draw.fillQuadAlpha(box_x, box_y, box_w, box_h, draw.bg, 0.95);
        draw.fillQuadAlpha(box_x, box_y, box_w, box_h, draw.accent, 0.22);
        _ = draw.renderTextLimited(form.mode, box_x + 18, box_y + draw.cell_h * 1.4, draw.fg, box_w - 36);
        var field: usize = 0;
        while (field < 8) : (field += 1) {
            const row_y = box_y + draw.cell_h * @as(f32, @floatFromInt(field + 3));
            if (field == form.focus) {
                draw.fillQuadAlpha(box_x + 12, row_y - draw.cell_h + 3, box_w - 24, draw.cell_h, draw.accent, 0.20);
            }
            var value_buf: [32]u8 = undefined;
            _ = draw.renderTextLimited(formFieldLabel(field), box_x + 22, row_y, draw.accent, 160);
            _ = draw.renderTextLimited(formFieldValue(form, field, &value_buf), box_x + 190, row_y, draw.fg, box_w - 220);
        }
    }
```

- [ ] **Step 4: Pass form data from AppWindow**

In `renderPortForwardingFrame`, compute:

```zig
    const form_view: ?port_forwarding_renderer.FormView = switch (session.model.overlay) {
        .form => |form| .{
            .mode = if (form.mode == .new) "New forwarding rule" else "Edit forwarding rule",
            .focus = form.focus,
            .rule = form.rule,
        },
        else => null,
    };
```

Add `.form = form_view,` to the `View` literal.

- [ ] **Step 5: Run focused and full tests**

Run:

```bash
zig test src/renderer/port_forwarding_renderer.zig
zig build test-full
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/renderer/port_forwarding_renderer.zig src/AppWindow.zig
git commit -m "feat(port-forward): render rule form"
```

---

### Task 11: Preserve Existing SSH Profile And URL Tunnel Behavior

**Files:**
- Modify: `src/test_main.zig`
- Test: `zig build test-full`

- [ ] **Step 1: Add source-guard tests**

In `src/test_main.zig`, add tests after the existing source-guard tests:

```zig
test "port forwarding does not extend ssh_hosts profile schema" {
    const profile_source = @embedFile("renderer/overlays/profile_codec.zig");
    try std.testing.expect(std.mem.indexOf(u8, profile_source, "pub const SSH_FIELD_COUNT = 6") != null);
    try std.testing.expect(std.mem.indexOf(u8, profile_source, "port_forward") == null);
}

test "existing ssh_tunnel remains URL-driven local forwarding" {
    const tunnel_source = @embedFile("ssh_tunnel.zig");
    try std.testing.expect(std.mem.indexOf(u8, tunnel_source, "\"-L\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tunnel_source, "\"-R\"") == null);
}
```

- [ ] **Step 2: Run full tests**

Run:

```bash
zig build test-full
```

Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add src/test_main.zig
git commit -m "test(port-forward): guard existing ssh surfaces"
```

---

### Task 12: Documentation And Manual Verification Notes

**Files:**
- Create: `docs/port-forwarding.md`
- Modify: `README.md`
- Test: markdown review, Windows manual checks

- [ ] **Step 1: Add feature documentation**

Create `docs/port-forwarding.md`:

```markdown
# Port Forwarding

Open **Port Forwarding** from the command center to manage silent SSH forwarding
rules. Rules are global and bind to saved SSH profiles. Closing the management
tab does not stop running forwarding helpers.

## Reverse Forwarding

Reverse forwarding lets a server use a local port on your workstation. The
common proxy/VPN rule is:

```text
Reverse: server 127.0.0.1:7890 -> local 127.0.0.1:7890
```

On the server:

```sh
export HTTP_PROXY=http://127.0.0.1:7890
export HTTPS_PROXY=http://127.0.0.1:7890
```

## Local Forwarding

Local forwarding lets a local browser or service use a loopback service on the
server:

```text
Local: local 127.0.0.1:8888 -> server 127.0.0.1:8888
```

## Safety Boundary

v1 only supports loopback hosts (`127.0.0.1` and `localhost`). It does not bind
`0.0.0.0` or other non-loopback addresses.

## SSH Compatibility

WispTerm starts independent OpenSSH helper processes and does not use
ControlMaster, ControlPersist, or ControlPath for forwarding helpers.
```

- [ ] **Step 2: Link docs from README**

In `README.md`, add a feature bullet near the embedded browser/SSH bullets:

```markdown
- **SSH port forwarding manager** - silently manage local and reverse SSH forwarding rules from a dedicated tab
```

Add a docs link near the other docs links:

```markdown
- [SSH port forwarding](docs/port-forwarding.md)
```

- [ ] **Step 3: Run tests**

Run:

```bash
zig build test
```

Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add README.md docs/port-forwarding.md
git commit -m "docs(port-forward): document forwarding manager"
```

---

### Task 13: Final Verification Gates

**Files:**
- No source edits expected unless a verification failure points to a bug.

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

- [ ] **Step 3: Run focused module tests**

Run:

```bash
zig test src/port_forward_rule.zig
zig test src/ssh_profile_store.zig
zig test src/port_forward_manager.zig
zig test src/port_forwarding.zig
zig test src/renderer/port_forwarding_renderer.zig
```

Expected: PASS for all five commands.

- [ ] **Step 4: Run Windows checkout-safety checks in PowerShell**

Run on Windows PowerShell:

```powershell
$paths = git ls-files
$reserved = @('CON', 'PRN', 'AUX', 'NUL') + (1..9 | ForEach-Object { "COM$_"; "LPT$_" })
$violations = [System.Collections.Generic.List[object]]::new()
$collisions = [System.Collections.Generic.List[object]]::new()
$seen = @{}

foreach ($path in $paths) {
    foreach ($part in ($path -split '/')) {
        $stem = ($part -split '\.')[0].ToUpperInvariant()
        $reasons = @()
        if ($part.IndexOfAny([char[]]'<>:"\|?*') -ge 0) { $reasons += 'illegal_char' }
        if ($part.EndsWith(' ') -or $part.EndsWith('.')) { $reasons += 'trailing_space_or_dot' }
        if ($reserved -contains $stem) { $reasons += 'reserved_name' }
        if ($reasons.Count -gt 0) {
            $violations.Add([pscustomobject]@{ Path = $path; Part = $part; Reasons = ($reasons -join ',') })
        }
    }

    $key = $path.ToLowerInvariant()
    if ($seen.ContainsKey($key) -and $seen[$key] -ne $path) {
        $collisions.Add([pscustomobject]@{ A = $seen[$key]; B = $path })
    } else {
        $seen[$key] = $path
    }
}

"tracked_files=$($paths.Count)"
"windows_name_violations=$($violations.Count)"
$violations | ForEach-Object { "violation`t$($_.Path)`t$($_.Part)`t$($_.Reasons)" }
"casefold_collisions=$($collisions.Count)"
$collisions | ForEach-Object { "collision`t$($_.A)`t$($_.B)" }
$longest = $paths | Sort-Object Length -Descending | Select-Object -First 1
"max_path_length=$($longest.Length) $longest"
git ls-files -s | Select-String '^120000'
```

Expected: `windows_name_violations=0`, `casefold_collisions=0`, and no symlink output.

- [ ] **Step 5: Manual Windows reverse forwarding check**

Use a saved SSH profile with access to a server and a local proxy on `127.0.0.1:7890`.

1. Open WispTerm.
2. Open Command Center -> `Port Forwarding`.
3. Create a reverse rule:

```text
Profile: devbox
Direction: Reverse
Remote host: 127.0.0.1
Remote port: 7890
Local host: 127.0.0.1
Local port: 7890
Auto start: On
Name: Local proxy
```

4. Start the rule with Space.
5. On the server, run:

```sh
curl -I -x http://127.0.0.1:7890 https://github.com
```

Expected: curl reaches GitHub through the local proxy, or any proxy-specific authentication error is from the local proxy rather than SSH forwarding.

- [ ] **Step 6: Manual Windows local forwarding check**

1. On the server, start a loopback HTTP service:

```sh
python3 -m http.server 8888 --bind 127.0.0.1
```

2. In WispTerm Port Forwarding, create:

```text
Profile: devbox
Direction: Local
Local host: 127.0.0.1
Local port: 8888
Remote host: 127.0.0.1
Remote port: 8888
Auto start: Off
Name: Remote HTTP
```

3. Start the rule.
4. Open `http://127.0.0.1:8888` in the local browser.

Expected: the browser shows the server directory listing.

- [ ] **Step 7: Manual compatibility checks**

Check:

- Password profile starts without printing the password.
- ProxyJump profile starts with the same jump host as the SSH profile.
- A failed remote bind shows an `Error` row and leaves useful OpenSSH stderr in the debug console.
- No helper command contains `ControlMaster`, `ControlPersist`, or `ControlPath`.

- [ ] **Step 8: Final commit if verification required fixes**

If any verification step required code changes:

```bash
git add src README.md docs
git commit -m "fix(port-forward): address verification findings"
```

If no changes were needed, do not create an empty commit.

---

## Self-Review Checklist

- Spec coverage:
  - Dedicated tab: Tasks 5, 6, 8, 9.
  - Global rules and auto-start: Tasks 3, 4, 7.
  - `-L` and `-R`: Tasks 1, 4, 13.
  - Separate storage from SSH profiles: Tasks 1, 7, 11.
  - Existing SSH profile page untouched: Tasks 2, 11.
  - Loopback-only v1: Tasks 1, 12.
  - No OpenSSH connection sharing: Tasks 4, 13.
  - Existing URL-click `ssh_tunnel.zig` unchanged: Task 11.
- Ghostty comparison included in plan header and architecture.
- No `remote/` work is included.
- Keyboard shortcut README rule is not triggered because no application shortcut binding is added; only tab-local keys are introduced.
- Full app input dirty rule is covered by Task 9's `input.zig` regression test.
