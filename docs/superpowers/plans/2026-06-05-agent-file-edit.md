# Agent file-edit tools (local + remote SSH) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the AI agent first-class `read_file` / `write_file` / `edit_file` tools that work on both local files and files on a remote SSH server, integrated with the existing access guard and approval UI.

**Architecture:** A new pure module `agent_file_edit.zig` holds all IO-free logic (exact-match edit, line slicing, unified diff, guards) and is unit-tested in the fast suite. The three tools live in `ai_chat_tools.zig`, dispatching local ops to `std.fs` and remote ops to `scp.zig` out-of-band SSH (`cat` / `cat >`), reusing the surface's `SshConnection` resolved by a new host callback. Tool schemas are added once to `forEachToolSpec` in `ai_chat_protocol.zig`. Approval reuses `approvalRequiredForGate`; the unified diff is posted to the transcript via a new `ToolContext.note` callback before the compact approval card.

**Tech Stack:** Zig (std.fs, std.json, std.process.Child), existing `ai_agent_access.zig` guard, `scp.zig` SSH transport.

---

## File Structure

- **Create** `src/agent_file_edit.zig` — pure logic: `applyEdit`, `looksBinary`, `sliceLinesAlloc`, `unifiedDiffAlloc`, `MAX_FILE_BYTES`. No IO. Unit-tested in fast suite.
- **Modify** `src/ai_agent_access.zig` — add `pathConfined` (path-based confinement, reuses internal normalizers).
- **Modify** `src/scp.zig` — add pure command builders `buildRemoteReadCommand` / `buildRemoteWriteCommand`, and thin transports `sshReadFile` / `sshWriteFile` (+ `sshExecStdin`).
- **Modify** `src/ai_chat_types.zig` — add `sshConnectionForSurface` (optional) to `ToolHost`; add `note` callback + `emitNote` / `sshConnectionForSurface` helpers to `ToolContext`.
- **Modify** `src/ai_chat.zig` — add public `appendLocalToolMessage`.
- **Modify** `src/ai_chat_request.zig` — wire `.note = toolNote`.
- **Modify** `src/AppWindow.zig` — implement `agentSshConnectionForSurface` host callback.
- **Modify** `src/ai_chat_tools.zig` — `jsonBoolArg`, `fileAccessGate`, the three tools + dispatch.
- **Modify** `src/ai_chat_protocol.zig` — register 3 schemas + schema-presence test.
- **Modify** `src/test_fast.zig` — register `agent_file_edit.zig`.
- **Modify** `src/prompt.md`, `src/wispterm_docs.zig`, `docs/*.md`, `wiki/*.md` — usage guidance.

**Verification commands (used throughout):**
- Fast pure suite: `zig build test` (exit 0).
- Full app suite: `zig build test-full` (exit 0; ~673+ passed, 0 failed baseline).
- Compile: `zig build`.

---

## Task 1: Pure module — `applyEdit`

**Files:**
- Create: `src/agent_file_edit.zig`
- Modify: `src/test_fast.zig` (register module)

- [ ] **Step 1: Create the module with `applyEdit` and its tests**

Create `src/agent_file_edit.zig`:

```zig
//! Pure, IO-free file-edit logic shared by the agent's read_file / write_file /
//! edit_file tools: exact-match string replacement, line slicing for reads,
//! unified diffs for the approval card, and size/binary guards. Leaf module —
//! no imports beyond std. All functions allocate only what they return (or a
//! scratch arena) so the fast test suite can exercise them without IO.
const std = @import("std");

/// Largest file (bytes) read_file/edit_file will load. Larger files are refused
/// with guidance to narrow the range, keeping a single edit in context.
pub const MAX_FILE_BYTES: usize = 256 * 1024;

pub const EditOutcome = struct {
    /// Owned by the caller's allocator.
    new_content: []u8,
    /// How many matches existed (1 unless replace_all replaced several).
    occurrences: usize,
};

pub const EditError = error{ EmptyOld, NotFound, NotUnique };

/// Replace `old_string` with `new_string` in `content`. With `replace_all`
/// false the match must be unique. Returns owned new content. Exact byte match.
pub fn applyEdit(
    allocator: std.mem.Allocator,
    content: []const u8,
    old_string: []const u8,
    new_string: []const u8,
    replace_all: bool,
) (EditError || error{OutOfMemory})!EditOutcome {
    if (old_string.len == 0) return error.EmptyOld;

    var count: usize = 0;
    var scan: usize = 0;
    while (std.mem.indexOfPos(u8, content, scan, old_string)) |pos| {
        count += 1;
        scan = pos + old_string.len;
    }
    if (count == 0) return error.NotFound;
    if (count > 1 and !replace_all) return error.NotUnique;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, content, cursor, old_string)) |pos| {
        try out.appendSlice(allocator, content[cursor..pos]);
        try out.appendSlice(allocator, new_string);
        cursor = pos + old_string.len;
        if (!replace_all) break;
    }
    try out.appendSlice(allocator, content[cursor..]);
    return .{ .new_content = try out.toOwnedSlice(allocator), .occurrences = count };
}

test "applyEdit replaces a unique match" {
    const a = std.testing.allocator;
    const r = try applyEdit(a, "alpha beta gamma", "beta", "BETA", false);
    defer a.free(r.new_content);
    try std.testing.expectEqualStrings("alpha BETA gamma", r.new_content);
    try std.testing.expectEqual(@as(usize, 1), r.occurrences);
}

test "applyEdit errors when not found" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.NotFound, applyEdit(a, "abc", "zzz", "x", false));
}

test "applyEdit errors when not unique without replace_all" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.NotUnique, applyEdit(a, "x x x", "x", "y", false));
}

test "applyEdit replace_all replaces every occurrence" {
    const a = std.testing.allocator;
    const r = try applyEdit(a, "x x x", "x", "y", true);
    defer a.free(r.new_content);
    try std.testing.expectEqualStrings("y y y", r.new_content);
    try std.testing.expectEqual(@as(usize, 3), r.occurrences);
}

test "applyEdit errors on empty old_string" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.EmptyOld, applyEdit(a, "abc", "", "x", false));
}

test "applyEdit preserves multiline content exactly" {
    const a = std.testing.allocator;
    const r = try applyEdit(a, "line1\nline2\nline3\n", "line2", "LINE2", false);
    defer a.free(r.new_content);
    try std.testing.expectEqualStrings("line1\nLINE2\nline3\n", r.new_content);
}
```

- [ ] **Step 2: Register the module in the fast suite**

In `src/test_fast.zig`, add after the `_ = @import("ai_agent_access.zig");` line:

```zig
    _ = @import("agent_file_edit.zig");
```

- [ ] **Step 3: Run the fast suite to verify it passes**

Run: `zig build test`
Expected: PASS (exit 0).

- [ ] **Step 4: Commit**

```bash
git add src/agent_file_edit.zig src/test_fast.zig
git commit -m "feat(agent): pure applyEdit for file-edit tools"
```

---

## Task 2: Pure module — `looksBinary` + `sliceLinesAlloc`

**Files:**
- Modify: `src/agent_file_edit.zig`

- [ ] **Step 1: Add the functions and tests**

Append to `src/agent_file_edit.zig` (before the existing tests is fine; functions before tests):

```zig
/// True if `content` looks binary (a NUL byte in the first 8 KiB).
pub fn looksBinary(content: []const u8) bool {
    const scan = content[0..@min(content.len, 8 * 1024)];
    return std.mem.indexOfScalar(u8, scan, 0) != null;
}

/// Render `content` as numbered lines `   <n>\t<line>\n` starting at 1-based
/// `offset` (0 means 1), emitting at most `limit` lines (0 means all). Owned.
pub fn sliceLinesAlloc(
    allocator: std.mem.Allocator,
    content: []const u8,
    offset: usize,
    limit: usize,
) ![]u8 {
    const start = if (offset == 0) 1 else offset;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var line_no: usize = 1;
    var emitted: usize = 0;
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| : (line_no += 1) {
        if (line_no < start) continue;
        if (limit != 0 and emitted >= limit) break;
        try out.print(allocator, "{d: >6}\t{s}\n", .{ line_no, line });
        emitted += 1;
    }
    return out.toOwnedSlice(allocator);
}
```

```zig
test "looksBinary detects NUL" {
    try std.testing.expect(looksBinary("ab\x00cd"));
    try std.testing.expect(!looksBinary("plain text\nlines"));
}

test "sliceLinesAlloc numbers from offset with a limit" {
    const a = std.testing.allocator;
    const r = try sliceLinesAlloc(a, "a\nb\nc\nd\n", 2, 2);
    defer a.free(r);
    try std.testing.expectEqualStrings("     2\tb\n     3\tc\n", r);
}

test "sliceLinesAlloc with offset 0 starts at line 1" {
    const a = std.testing.allocator;
    const r = try sliceLinesAlloc(a, "x\ny\n", 0, 0);
    defer a.free(r);
    try std.testing.expectEqualStrings("     1\tx\n     2\ty\n     3\t\n", r);
}
```

- [ ] **Step 2: Run the fast suite**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add src/agent_file_edit.zig
git commit -m "feat(agent): looksBinary + sliceLinesAlloc for read_file"
```

---

## Task 3: Pure module — `unifiedDiffAlloc`

**Files:**
- Modify: `src/agent_file_edit.zig`

- [ ] **Step 1: Add the diff function and tests**

Append to `src/agent_file_edit.zig`:

```zig
/// Split `text` into lines, dropping a single trailing empty element so a final
/// newline does not produce a phantom blank line. Caller frees the outer slice
/// (line slices alias `text`).
fn splitLines(allocator: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer lines.deinit(allocator);
    if (text.len == 0) return lines.toOwnedSlice(allocator);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| try lines.append(allocator, line);
    if (lines.items.len > 0 and lines.items[lines.items.len - 1].len == 0) {
        _ = lines.pop();
    }
    return lines.toOwnedSlice(allocator);
}

/// Produce a minimal unified diff of `old` -> `new` for `path`. Trims common
/// leading/trailing lines and emits one hunk of removals then additions. Owned.
pub fn unifiedDiffAlloc(
    allocator: std.mem.Allocator,
    path: []const u8,
    old: []const u8,
    new: []const u8,
) ![]u8 {
    const old_lines = try splitLines(allocator, old);
    defer allocator.free(old_lines);
    const new_lines = try splitLines(allocator, new);
    defer allocator.free(new_lines);

    var p: usize = 0;
    while (p < old_lines.len and p < new_lines.len and
        std.mem.eql(u8, old_lines[p], new_lines[p])) : (p += 1)
    {}
    var s: usize = 0;
    while (s < old_lines.len - p and s < new_lines.len - p and
        std.mem.eql(u8, old_lines[old_lines.len - 1 - s], new_lines[new_lines.len - 1 - s])) : (s += 1)
    {}

    const old_count = old_lines.len - p - s;
    const new_count = new_lines.len - p - s;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.print(allocator, "--- a/{s}\n+++ b/{s}\n", .{ path, path });
    try out.print(allocator, "@@ -{d},{d} +{d},{d} @@\n", .{ p + 1, old_count, p + 1, new_count });
    for (old_lines[p .. old_lines.len - s]) |line| try out.print(allocator, "-{s}\n", .{line});
    for (new_lines[p .. new_lines.len - s]) |line| try out.print(allocator, "+{s}\n", .{line});
    return out.toOwnedSlice(allocator);
}
```

```zig
test "unifiedDiffAlloc shows a single changed line" {
    const a = std.testing.allocator;
    const d = try unifiedDiffAlloc(a, "f.txt", "a\nb\nc\n", "a\nB\nc\n");
    defer a.free(d);
    try std.testing.expectEqualStrings(
        "--- a/f.txt\n+++ b/f.txt\n@@ -2,1 +2,1 @@\n-b\n+B\n",
        d,
    );
}

test "unifiedDiffAlloc for a new file shows only additions" {
    const a = std.testing.allocator;
    const d = try unifiedDiffAlloc(a, "n.txt", "", "x\ny\n");
    defer a.free(d);
    try std.testing.expectEqualStrings(
        "--- a/n.txt\n+++ b/n.txt\n@@ -1,0 +1,2 @@\n+x\n+y\n",
        d,
    );
}
```

- [ ] **Step 2: Run the fast suite**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add src/agent_file_edit.zig
git commit -m "feat(agent): unifiedDiffAlloc for edit/write approval"
```

---

## Task 4: `ai_agent_access.pathConfined`

**Files:**
- Modify: `src/ai_agent_access.zig`

- [ ] **Step 1: Add `pathConfined` after `workdirConfined`**

In `src/ai_agent_access.zig`, immediately after the closing `}` of `workdirConfined` (the function ending near line 269), add:

```zig
/// True when a single `path` (the only argument to a file op) stays inside
/// `working_dir`. Relative paths resolve against `effective_cwd` (which must
/// itself be inside the working dir); `~` expands to `home`. Pure; the
/// allocator backs only a scratch arena. Mirrors `workdirConfined` for one path.
pub fn pathConfined(
    allocator: std.mem.Allocator,
    path: []const u8,
    working_dir: []const u8,
    effective_cwd: []const u8,
    home: []const u8,
) bool {
    if (working_dir.len == 0 or path.len == 0) return false;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const root = normForCompare(a, working_dir) catch return false;
    const base = (resolveForConfine(a, effective_cwd, home, root) catch null) orelse root;
    if (!matchesRoot(base, root)) return false;
    const resolved = (resolveForConfine(a, path, home, base) catch null) orelse return false;
    return matchesRoot(resolved, root);
}
```

- [ ] **Step 2: Add tests at the end of the file's test block**

Append after the existing `workdirConfined` tests:

```zig
test "pathConfined: inside the working dir is confined" {
    const a = std.testing.allocator;
    const wd = "/home/u/proj";
    try std.testing.expect(pathConfined(a, "src/main.zig", wd, "/home/u/proj", "/home/u"));
    try std.testing.expect(pathConfined(a, "/home/u/proj/notes.txt", wd, "/home/u/proj", "/home/u"));
}

test "pathConfined: escaping or outside paths are not confined" {
    const a = std.testing.allocator;
    const wd = "/home/u/proj";
    try std.testing.expect(!pathConfined(a, "../secret.txt", wd, "/home/u/proj", "/home/u"));
    try std.testing.expect(!pathConfined(a, "/etc/passwd", wd, "/home/u/proj", "/home/u"));
    try std.testing.expect(!pathConfined(a, "a.txt", "", "/home/u/proj", "/home/u"));
}
```

- [ ] **Step 3: Run the fast suite**

Run: `zig build test`
Expected: PASS (`ai_agent_access.zig` is registered in the fast suite).

- [ ] **Step 4: Commit**

```bash
git add src/ai_agent_access.zig
git commit -m "feat(access): pathConfined for path-based file gating"
```

---

## Task 5: `scp.zig` remote read/write transport

**Files:**
- Modify: `src/scp.zig`

- [ ] **Step 1: Add pure command builders + tests**

In `src/scp.zig`, after `buildDownloadCommand` (near line 388), add:

```zig
/// Build `cat -- '<path>'` to stream a remote file's bytes to stdout.
pub fn buildRemoteReadCommand(buf: *[2048]u8, path: []const u8) ?[]const u8 {
    var pos: usize = 0;
    if (!appendSlice(buf, &pos, "cat -- ")) return null;
    if (!appendShellQuote(buf, &pos, path)) return null;
    return buf[0..pos];
}

/// Build `cat > '<tmp>' && mv -- '<tmp>' '<path>'` for an atomic remote write
/// (content arrives on stdin).
pub fn buildRemoteWriteCommand(buf: *[2048]u8, path: []const u8, tmp: []const u8) ?[]const u8 {
    var pos: usize = 0;
    if (!appendSlice(buf, &pos, "cat > ")) return null;
    if (!appendShellQuote(buf, &pos, tmp)) return null;
    if (!appendSlice(buf, &pos, " && mv -- ")) return null;
    if (!appendShellQuote(buf, &pos, tmp)) return null;
    if (!appendSlice(buf, &pos, " ")) return null;
    if (!appendShellQuote(buf, &pos, path)) return null;
    return buf[0..pos];
}

test "buildRemoteReadCommand quotes the path" {
    var buf: [2048]u8 = undefined;
    const cmd = buildRemoteReadCommand(&buf, "/tmp/a b.txt").?;
    try std.testing.expectEqualStrings("cat -- '/tmp/a b.txt'", cmd);
}

test "buildRemoteWriteCommand builds an atomic temp+mv" {
    var buf: [2048]u8 = undefined;
    const cmd = buildRemoteWriteCommand(&buf, "/tmp/a.txt", "/tmp/a.txt.tmp").?;
    try std.testing.expectEqualStrings("cat > '/tmp/a.txt.tmp' && mv -- '/tmp/a.txt.tmp' '/tmp/a.txt'", cmd);
}
```

- [ ] **Step 2: Add the transport wrappers**

After the builders, add `sshReadFile`, `sshWriteFile`, and `sshExecStdin`:

```zig
/// Read a remote file via `ssh ... cat`. Returns owned bytes, null on failure.
pub fn sshReadFile(allocator: std.mem.Allocator, conn: *const SshConnection, path: []const u8) ?[]u8 {
    var buf: [2048]u8 = undefined;
    const cmd = buildRemoteReadCommand(&buf, path) orelse return null;
    return sshExec(allocator, conn, cmd);
}

/// Write `content` to a remote file atomically (temp + mv) via `ssh ... cat >`.
pub fn sshWriteFile(allocator: std.mem.Allocator, conn: *const SshConnection, path: []const u8, content: []const u8) bool {
    var tmp_buf: [600]u8 = undefined;
    const tmp = std.fmt.bufPrint(&tmp_buf, "{s}.wispterm.tmp", .{path}) catch return false;
    var cmd_buf: [2048]u8 = undefined;
    const cmd = buildRemoteWriteCommand(&cmd_buf, path, tmp) orelse return false;
    return sshExecStdin(allocator, conn, cmd, content);
}

/// Run `ssh user@host "<command>"` piping `stdin_bytes` to the remote stdin.
/// Returns true on exit code 0. Mirrors `sshExec`'s askpass env setup.
fn sshExecStdin(allocator: std.mem.Allocator, conn: *const SshConnection, command: []const u8, stdin_bytes: []const u8) bool {
    var askpass_path: ?[]const u8 = null;
    defer if (askpass_path) |p| allocator.free(p);
    var env_map: ?std.process.EnvMap = null;
    defer if (env_map) |*map| map.deinit();
    if (conn.password_auth) {
        askpass_path = platform_process.ensureSshAskPassScript(allocator) orelse return false;
        env_map = std.process.getEnvMap(allocator) catch return false;
        if (env_map) |*map| {
            map.put("SSH_ASKPASS", askpass_path.?) catch return false;
            map.put("SSH_ASKPASS_REQUIRE", "force") catch return false;
            map.put("DISPLAY", "wispterm") catch return false;
            map.put("WISPTERM_SSH_PASSWORD", conn.password()) catch return false;
        }
    }

    var argv_buf: [32][]const u8 = undefined;
    var argc: usize = 0;
    argv_buf[argc] = platform_pty_command.sshExecutableName();
    argc += 1;
    argc = appendSshOptions(&argv_buf, argc, conn, .ssh, null);
    var dest_buf: [280]u8 = undefined;
    const dest_len = conn.user().len + 1 + conn.host().len;
    @memcpy(dest_buf[0..conn.user().len], conn.user());
    dest_buf[conn.user().len] = '@';
    @memcpy(dest_buf[conn.user().len + 1 ..][0..conn.host().len], conn.host());
    argv_buf[argc] = dest_buf[0..dest_len];
    argc += 1;
    argv_buf[argc] = command;
    argc += 1;

    var child = std.process.Child.init(argv_buf[0..argc], allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Pipe;
    if (env_map) |*map| child.env_map = map;
    child.create_no_window = true;
    child.spawn() catch return false;

    if (child.stdin) |stdin| {
        stdin.writeAll(stdin_bytes) catch {};
        stdin.close();
        child.stdin = null;
    }
    if (child.stderr) |stderr| {
        const drained = stderr.readToEndAlloc(allocator, 16 * 1024) catch null;
        if (drained) |d| allocator.free(d);
    }
    const term = child.wait() catch return false;
    return switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
}
```

- [ ] **Step 3: Run the fast suite (scp.zig is registered there)**

Run: `zig build test`
Expected: PASS (the two builder tests run; transports compile).

- [ ] **Step 4: Commit**

```bash
git add src/scp.zig
git commit -m "feat(scp): out-of-band remote file read/write helpers"
```

---

## Task 6: `ToolHost` + `ToolContext` seam (host callback + note)

**Files:**
- Modify: `src/ai_chat_types.zig`

- [ ] **Step 1: Import `SshConnection` and extend `ToolHost`**

In `src/ai_chat_types.zig`, add an import near the other imports at the top:

```zig
const ssh_connection = @import("ssh_connection.zig");
pub const SshConnection = ssh_connection.SshConnection;
```

In the `ToolHost` struct, add a trailing field WITH a default (so existing host literals compile unchanged):

```zig
    /// Resolve `surface_id` to its SSH connection for out-of-band file IO, or
    /// null for local/WSL/unknown surfaces. Only the real AppWindow host sets
    /// this; others leave it null (file tools then treat the target as local).
    sshConnectionForSurface: ?*const fn (*anyopaque, []const u8) ?SshConnection = null,
```

- [ ] **Step 2: Add the `note` callback + helpers to `ToolContext`**

In `ToolContext`, add a module-level no-op above the struct (or just below it) and a defaulted field. First, above `pub const ToolContext`:

```zig
fn noopNote(_: *anyopaque, _: []const u8) void {}
```

Then add the field to `ToolContext` (after `cancelled`):

```zig
    /// Post a transcript note (e.g. a diff) before an approval prompt. Defaults
    /// to a no-op so test contexts need not wire it.
    note: *const fn (ctx: *anyopaque, text: []const u8) void = noopNote,
```

And add helper methods inside `ToolContext` (after `requestApproval`):

```zig
    pub fn emitNote(self: *const ToolContext, text: []const u8) void {
        self.note(self.ctx, text);
    }
    pub fn sshConnectionForSurface(self: *const ToolContext, surface_id: []const u8) ?SshConnection {
        const host = self.tool_host orelse return null;
        const resolver = host.sshConnectionForSurface orelse return null;
        return resolver(host.ctx, surface_id);
    }
```

- [ ] **Step 3: Compile (no behavior change yet)**

Run: `zig build`
Expected: builds (existing `ToolHost` literals still valid because new fields are defaulted).

- [ ] **Step 4: Run both suites**

Run: `zig build test && zig build test-full`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/ai_chat_types.zig
git commit -m "feat(agent): ToolHost ssh-conn resolver + ToolContext note seam"
```

---

## Task 7: Wire the transcript note (Session side)

**Files:**
- Modify: `src/ai_chat.zig`
- Modify: `src/ai_chat_request.zig`

- [ ] **Step 1: Add a public, locking `appendLocalToolMessage` to Session**

In `src/ai_chat.zig`, right after the `appendLocalToolMessageLocked` method (near line 1532), add:

```zig
    /// Thread-safe wrapper used by the tool layer (worker thread) to post a
    /// transcript note such as a diff. Swallows OOM (best-effort UI message).
    pub fn appendLocalToolMessage(self: *Session, text: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.appendLocalToolMessageLocked(text) catch {};
    }
```

- [ ] **Step 2: Wire the `toolNote` adapter into the ToolContext**

In `src/ai_chat_request.zig`, after `toolCancelled` (near line 502), add:

```zig
fn toolNote(ctx: *anyopaque, text: []const u8) void {
    const session: *Session = @ptrCast(@alignCast(ctx));
    session.appendLocalToolMessage(text);
}
```

Then in `toolContextFromRequest`, add the field to the returned struct (after `.cancelled = toolCancelled,`):

```zig
        .note = toolNote,
```

- [ ] **Step 3: Run both suites**

Run: `zig build test && zig build test-full`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add src/ai_chat.zig src/ai_chat_request.zig
git commit -m "feat(agent): wire transcript note callback to Session"
```

---

## Task 8: Implement the AppWindow host callback

**Files:**
- Modify: `src/AppWindow.zig`

- [ ] **Step 1: Implement `agentSshConnectionForSurface`**

In `src/AppWindow.zig`, after `agentWriteSurface` (near line 3522), add a by-id resolver that copies the connection value (avoids dereferencing a worker-held pointer):

```zig
fn agentSshConnectionForSurface(ctx: *anyopaque, surface_id: []const u8) ?Surface.SshConnection {
    _ = ctx;
    if (surface_id.len == 0) return null;
    for (0..tab.g_tab_count) |tab_index| {
        const tab_state = tab.g_tabs[tab_index] orelse continue;
        if (tab_state.kind != .terminal) continue;
        var it = tab_state.tree.iterator();
        while (it.next()) |entry| {
            const sfc = entry.surface;
            if (!std.mem.eql(u8, sfc.remote_id[0..], surface_id)) continue;
            return sfc.ssh_connection; // value copy (or null if not SSH)
        }
    }
    return null;
}
```

> Note: `Surface.remote_id` is a fixed buffer compared the same way as in `collectAgentToolSnapshot`. If `remote_id` is not full-length there, match the slice form used by `makeAgentToolSurface` (check that function and mirror its comparison exactly).

- [ ] **Step 2: Register it in `installAgentToolHost`**

In `installAgentToolHost` (near line 3930), add to the `setToolHost` literal:

```zig
        .sshConnectionForSurface = agentSshConnectionForSurface,
```

- [ ] **Step 3: Compile + run full suite**

Run: `zig build && zig build test-full`
Expected: builds and PASS.

- [ ] **Step 4: Commit**

```bash
git add src/AppWindow.zig
git commit -m "feat(agent): resolve surface ssh connection for file tools"
```

---

## Task 9: `ai_chat_tools` gate + `jsonBoolArg`

**Files:**
- Modify: `src/ai_chat_tools.zig`

- [ ] **Step 1: Add `jsonBoolArg` and `fileAccessGate` with tests**

In `src/ai_chat_tools.zig`, after `jsonIndexArg` (near line 181), add:

```zig
fn jsonBoolArg(root: std.json.Value, name: []const u8) ?bool {
    if (root != .object) return null;
    const value = root.object.get(name) orelse return null;
    return switch (value) {
        .bool => |b| b,
        else => null,
    };
}
```

Add the import for the pure module near the other imports at the top:

```zig
const agent_file_edit = @import("agent_file_edit.zig");
```

After `accessGate` (near line 477), add a path-aware gate:

```zig
/// Gate a local file path. Reads only check the deny-list; writes additionally
/// flag paths outside the working dir as risky (force). `working_dir` is the
/// effective cwd for resolving relatives. Reuses the command guard's semantics
/// via the shared AccessGate shape so approvalRequiredForGate maps the same way.
fn fileAccessGate(ctx: *const ToolContext, path: []const u8, is_write: bool) AccessGate {
    const rules = ctx.settings.access_rules;
    const denied = if (rules) |r| ai_agent_access.isPathDenied(ctx.allocator, r, path, ctx.settings.working_dir) else false;
    const home = if (rules) |r| r.home else "";
    const confined = blk: {
        const wd = ctx.settings.working_dir orelse break :blk false;
        break :blk ai_agent_access.pathConfined(ctx.allocator, path, wd, wd, home);
    };
    const risky = is_write and !confined;
    return .{
        .dangerous = risky,
        .blacklisted = denied,
        .force = denied or risky,
        .skip = if (is_write) (confined and !denied) else !denied,
        .matched = if (denied) path else "",
    };
}

/// Gate a remote file op: reads never prompt; writes are risky-by-default
/// (cannot confine-check a remote path) so they prompt unless permission=full.
fn remoteFileGate(is_write: bool) AccessGate {
    return .{
        .dangerous = is_write,
        .blacklisted = false,
        .force = is_write,
        .skip = !is_write,
        .matched = "",
    };
}
```

```zig
test "fileAccessGate: read of a normal path does not force approval" {
    var ctx = try testToolContext(std.testing.allocator);
    defer ctx.deinit();
    const gate = fileAccessGate(&ctx.value, "/work/readme.txt", false);
    try std.testing.expect(!gate.force);
    try std.testing.expect(gate.skip);
}

test "remoteFileGate: writes force approval, reads do not" {
    try std.testing.expect(remoteFileGate(true).force);
    try std.testing.expect(!remoteFileGate(false).force);
    try std.testing.expect(remoteFileGate(false).skip);
}
```

> `testToolContext` helper: if a minimal ToolContext test factory does not already exist in this file, add one near the existing tests that builds a `ToolContext` with `settings = .{}` (default permission), `tool_host = null`, `approve`/`cancelled` no-op stubs. Reuse any existing test ToolContext builder in the file (search for `ToolContext{` in the test section) rather than duplicating.

- [ ] **Step 2: Run full suite (ai_chat_tools tests run under test-full)**

Run: `zig build test-full`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add src/ai_chat_tools.zig
git commit -m "feat(agent): jsonBoolArg + path-aware file access gate"
```

---

## Task 10: `read_file` tool

**Files:**
- Modify: `src/ai_chat_tools.zig`

- [ ] **Step 1: Add a local-read helper + the tool implementation**

In `src/ai_chat_tools.zig`, add near the other tool implementations:

```zig
/// Resolve `path` against `working_dir` if relative, then return an owned copy.
fn resolveLocalPath(allocator: std.mem.Allocator, path: []const u8, working_dir: ?[]const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    if (working_dir) |wd| if (wd.len != 0) return std.fs.path.join(allocator, &.{ wd, path });
    return allocator.dupe(u8, path);
}

fn readFileTool(ctx: *ToolContext, path: []const u8, surface_id: ?[]const u8, offset: usize, limit: usize) ![]u8 {
    if (ctx.isCancelled()) return ctx.allocator.dupe(u8, "Canceled.");

    // Remote?
    if (surface_id) |sid| {
        if (ctx.sshConnectionForSurface(sid)) |conn| {
            const gate = remoteFileGate(false);
            if (approvalRequiredForGate(ctx.settings.permission, gate)) {
                if (!ctx.requestApproval("read_file", path, "Read remote file")) {
                    return deniedResult(ctx.allocator, path, "operator rejected remote read");
                }
            }
            const bytes = scp.sshReadFile(ctx.allocator, &conn, path) orelse
                return std.fmt.allocPrint(ctx.allocator, "Failed to read remote file {s}", .{path});
            defer ctx.allocator.free(bytes);
            return renderReadResult(ctx, path, bytes, offset, limit);
        }
        // surface_id provided but not an SSH surface: fall through to local.
    }

    const gate = fileAccessGate(ctx, path, false);
    if (approvalRequiredForGate(ctx.settings.permission, gate)) {
        const reason = if (gate.blacklisted) "Reads a protected path - confirm to allow" else "Read file";
        if (!ctx.requestApproval("read_file", path, reason)) {
            return deniedResult(ctx.allocator, path, "operator rejected file read");
        }
    }
    const resolved = try resolveLocalPath(ctx.allocator, path, ctx.settings.working_dir);
    defer ctx.allocator.free(resolved);
    const bytes = std.fs.cwd().readFileAlloc(ctx.allocator, resolved, agent_file_edit.MAX_FILE_BYTES) catch |err| {
        return std.fmt.allocPrint(ctx.allocator, "Failed to read {s}: {s}", .{ path, @errorName(err) });
    };
    defer ctx.allocator.free(bytes);
    return renderReadResult(ctx, path, bytes, offset, limit);
}

fn renderReadResult(ctx: *ToolContext, path: []const u8, bytes: []const u8, offset: usize, limit: usize) ![]u8 {
    if (bytes.len >= agent_file_edit.MAX_FILE_BYTES) {
        return std.fmt.allocPrint(ctx.allocator, "File {s} is too large (>= {d} bytes). Use offset/limit to read a range.", .{ path, agent_file_edit.MAX_FILE_BYTES });
    }
    if (agent_file_edit.looksBinary(bytes)) {
        return std.fmt.allocPrint(ctx.allocator, "File {s} appears to be binary; refusing to read as text.", .{path});
    }
    const numbered = try agent_file_edit.sliceLinesAlloc(ctx.allocator, bytes, offset, limit);
    return truncateOwned(ctx.allocator, ctx.settings, numbered);
}
```

Add the `scp` import near the top imports if not present:

```zig
const scp = @import("scp.zig");
```

- [ ] **Step 2: Add the dispatch branch**

In `executeToolCall`, before the `skill_info` branch, add:

```zig
    if (std.mem.eql(u8, call.name, "read_file")) {
        const args = parseArgs(ctx.allocator, call.arguments) orelse return ctx.allocator.dupe(u8, "Invalid tool arguments");
        defer args.deinit();
        const path = jsonStringArg(args.value, "path") orelse return ctx.allocator.dupe(u8, "Missing path");
        const surface_id = jsonStringArg(args.value, "surface_id");
        const offset = jsonIndexArg(args.value, "offset") orelse 0;
        const limit = jsonIndexArg(args.value, "limit") orelse 0;
        return readFileTool(ctx, path, surface_id, offset, limit);
    }
```

- [ ] **Step 3: Add a test for local read**

Add to the test section (reuse the test ToolContext factory; write a temp file under a tmp dir):

```zig
test "read_file returns numbered lines for a local file" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "r.txt", .data = "one\ntwo\n" });
    const abs = try tmp.dir.realpathAlloc(a, "r.txt");
    defer a.free(abs);

    var ctx = try testToolContext(a);
    defer ctx.deinit();
    const out = try readFileTool(&ctx.value, abs, null, 0, 0);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "     1\tone\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "     2\ttwo\n") != null);
}
```

- [ ] **Step 4: Run the full suite**

Run: `zig build test-full`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/ai_chat_tools.zig
git commit -m "feat(agent): read_file tool (local + remote SSH)"
```

---

## Task 11: `write_file` tool

**Files:**
- Modify: `src/ai_chat_tools.zig`

- [ ] **Step 1: Add an atomic local-write helper + the tool**

In `src/ai_chat_tools.zig`, add:

```zig
fn writeLocalFileAtomic(allocator: std.mem.Allocator, resolved: []const u8, content: []const u8) !void {
    const dir = std.fs.path.dirname(resolved) orelse ".";
    const base = std.fs.path.basename(resolved);
    var dir_handle = try std.fs.cwd().makeOpenPath(dir, .{});
    defer dir_handle.close();
    const tmp_name = try std.fmt.allocPrint(allocator, ".wispterm-tmp-{s}", .{base});
    defer allocator.free(tmp_name);
    try dir_handle.writeFile(.{ .sub_path = tmp_name, .data = content });
    try dir_handle.rename(tmp_name, base);
}

fn writeFileTool(ctx: *ToolContext, path: []const u8, content: []const u8, surface_id: ?[]const u8) ![]u8 {
    if (ctx.isCancelled()) return ctx.allocator.dupe(u8, "Canceled.");

    // Compute old content for the diff (empty if the file does not exist yet).
    var old_content: []u8 = &[_]u8{};
    var owns_old = false;
    defer if (owns_old) ctx.allocator.free(old_content);

    const remote_conn: ?agent_file_edit_SshConn = blk: {
        if (surface_id) |sid| {
            if (ctx.sshConnectionForSurface(sid)) |conn| break :blk conn;
        }
        break :blk null;
    };

    if (remote_conn) |conn| {
        if (scp.sshReadFile(ctx.allocator, &conn, path)) |bytes| {
            old_content = bytes;
            owns_old = true;
        }
    } else {
        const resolved = try resolveLocalPath(ctx.allocator, path, ctx.settings.working_dir);
        defer ctx.allocator.free(resolved);
        if (std.fs.cwd().readFileAlloc(ctx.allocator, resolved, agent_file_edit.MAX_FILE_BYTES)) |bytes| {
            old_content = bytes;
            owns_old = true;
        } else |_| {}
    }

    // Diff to the transcript, then approval.
    const diff = try agent_file_edit.unifiedDiffAlloc(ctx.allocator, path, old_content, content);
    defer ctx.allocator.free(diff);
    ctx.emitNote(diff);

    const gate = if (remote_conn != null) remoteFileGate(true) else fileAccessGate(ctx, path, true);
    if (approvalRequiredForGate(ctx.settings.permission, gate)) {
        const reason = try std.fmt.allocPrint(ctx.allocator, "Write {s}", .{path});
        defer ctx.allocator.free(reason);
        if (!ctx.requestApproval("write_file", path, reason)) {
            return deniedResult(ctx.allocator, path, "operator rejected file write");
        }
    }

    if (remote_conn) |conn| {
        if (!scp.sshWriteFile(ctx.allocator, &conn, path, content)) {
            return std.fmt.allocPrint(ctx.allocator, "Failed to write remote file {s}", .{path});
        }
    } else {
        const resolved = try resolveLocalPath(ctx.allocator, path, ctx.settings.working_dir);
        defer ctx.allocator.free(resolved);
        writeLocalFileAtomic(ctx.allocator, resolved, content) catch |err| {
            return std.fmt.allocPrint(ctx.allocator, "Failed to write {s}: {s}", .{ path, @errorName(err) });
        };
    }
    return std.fmt.allocPrint(ctx.allocator, "Wrote {d} bytes to {s}", .{ content.len, path });
}
```

Add the connection alias near the top imports (so the `remote_conn` local has a concrete type):

```zig
const agent_file_edit_SshConn = types.SshConnection;
```

- [ ] **Step 2: Add the dispatch branch**

In `executeToolCall`, before `skill_info` (after the `read_file` branch), add:

```zig
    if (std.mem.eql(u8, call.name, "write_file")) {
        const args = parseArgs(ctx.allocator, call.arguments) orelse return ctx.allocator.dupe(u8, "Invalid tool arguments");
        defer args.deinit();
        const path = jsonStringArg(args.value, "path") orelse return ctx.allocator.dupe(u8, "Missing path");
        const content = jsonStringArg(args.value, "content") orelse return ctx.allocator.dupe(u8, "Missing content");
        const surface_id = jsonStringArg(args.value, "surface_id");
        return writeFileTool(ctx, path, content, surface_id);
    }
```

- [ ] **Step 3: Add a test for local write (full mode = no prompt)**

```zig
test "write_file creates a local file in full permission mode" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_abs = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir_abs);
    const file_abs = try std.fs.path.join(a, &.{ dir_abs, "w.txt" });
    defer a.free(file_abs);

    var ctx = try testToolContext(a);
    defer ctx.deinit();
    ctx.value.settings.permission = .full; // no approval prompt
    const out = try writeFileTool(&ctx.value, file_abs, "hello\n", null);
    defer a.free(out);

    const written = try tmp.dir.readFileAlloc(a, "w.txt", 1024);
    defer a.free(written);
    try std.testing.expectEqualStrings("hello\n", written);
}
```

- [ ] **Step 4: Run the full suite**

Run: `zig build test-full`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/ai_chat_tools.zig
git commit -m "feat(agent): write_file tool (local + remote SSH) with diff"
```

---

## Task 12: `edit_file` tool

**Files:**
- Modify: `src/ai_chat_tools.zig`

- [ ] **Step 1: Add the tool implementation**

In `src/ai_chat_tools.zig`, add:

```zig
fn editFileTool(ctx: *ToolContext, path: []const u8, old_string: []const u8, new_string: []const u8, replace_all: bool, surface_id: ?[]const u8) ![]u8 {
    if (ctx.isCancelled()) return ctx.allocator.dupe(u8, "Canceled.");

    const remote_conn: ?agent_file_edit_SshConn = blk: {
        if (surface_id) |sid| {
            if (ctx.sshConnectionForSurface(sid)) |conn| break :blk conn;
        }
        break :blk null;
    };

    // Read current content.
    var old_content: []u8 = undefined;
    if (remote_conn) |conn| {
        old_content = scp.sshReadFile(ctx.allocator, &conn, path) orelse
            return std.fmt.allocPrint(ctx.allocator, "Failed to read remote file {s} for editing", .{path});
    } else {
        const resolved = try resolveLocalPath(ctx.allocator, path, ctx.settings.working_dir);
        defer ctx.allocator.free(resolved);
        old_content = std.fs.cwd().readFileAlloc(ctx.allocator, resolved, agent_file_edit.MAX_FILE_BYTES) catch |err|
            return std.fmt.allocPrint(ctx.allocator, "Failed to read {s}: {s}", .{ path, @errorName(err) });
    }
    defer ctx.allocator.free(old_content);

    // Apply the edit in memory.
    const outcome = agent_file_edit.applyEdit(ctx.allocator, old_content, old_string, new_string, replace_all) catch |err| {
        return switch (err) {
            error.EmptyOld => ctx.allocator.dupe(u8, "old_string must not be empty."),
            error.NotFound => std.fmt.allocPrint(ctx.allocator, "old_string not found in {s}.", .{path}),
            error.NotUnique => std.fmt.allocPrint(ctx.allocator, "old_string is not unique in {s}; pass replace_all=true or add more context.", .{path}),
            error.OutOfMemory => error.OutOfMemory,
        };
    };
    defer ctx.allocator.free(outcome.new_content);

    // Diff to the transcript, then approval.
    const diff = try agent_file_edit.unifiedDiffAlloc(ctx.allocator, path, old_content, outcome.new_content);
    defer ctx.allocator.free(diff);
    ctx.emitNote(diff);

    const gate = if (remote_conn != null) remoteFileGate(true) else fileAccessGate(ctx, path, true);
    if (approvalRequiredForGate(ctx.settings.permission, gate)) {
        const reason = try std.fmt.allocPrint(ctx.allocator, "Edit {s} ({d} change(s))", .{ path, outcome.occurrences });
        defer ctx.allocator.free(reason);
        if (!ctx.requestApproval("edit_file", path, reason)) {
            return deniedResult(ctx.allocator, path, "operator rejected file edit");
        }
    }

    // Write back.
    if (remote_conn) |conn| {
        if (!scp.sshWriteFile(ctx.allocator, &conn, path, outcome.new_content)) {
            return std.fmt.allocPrint(ctx.allocator, "Failed to write remote file {s}", .{path});
        }
    } else {
        const resolved = try resolveLocalPath(ctx.allocator, path, ctx.settings.working_dir);
        defer ctx.allocator.free(resolved);
        writeLocalFileAtomic(ctx.allocator, resolved, outcome.new_content) catch |err|
            return std.fmt.allocPrint(ctx.allocator, "Failed to write {s}: {s}", .{ path, @errorName(err) });
    }
    return std.fmt.allocPrint(ctx.allocator, "Edited {s} ({d} change(s)).", .{ path, outcome.occurrences });
}
```

- [ ] **Step 2: Add the dispatch branch**

In `executeToolCall`, before `skill_info` (after the `write_file` branch), add:

```zig
    if (std.mem.eql(u8, call.name, "edit_file")) {
        const args = parseArgs(ctx.allocator, call.arguments) orelse return ctx.allocator.dupe(u8, "Invalid tool arguments");
        defer args.deinit();
        const path = jsonStringArg(args.value, "path") orelse return ctx.allocator.dupe(u8, "Missing path");
        const old_string = jsonStringArg(args.value, "old_string") orelse return ctx.allocator.dupe(u8, "Missing old_string");
        const new_string = jsonStringArg(args.value, "new_string") orelse return ctx.allocator.dupe(u8, "Missing new_string");
        const replace_all = jsonBoolArg(args.value, "replace_all") orelse false;
        const surface_id = jsonStringArg(args.value, "surface_id");
        return editFileTool(ctx, path, old_string, new_string, replace_all, surface_id);
    }
```

> Note on `new_string`: `jsonStringArg` returns null for an empty string, which would reject a deletion edit (`new_string=""`). If empty `new_string` must be supported, read it directly: `const new_string = if (args.value == .object) (if (args.value.object.get("new_string")) |v| (if (v == .string) v.string else null) else null) else null; ... orelse return ... "Missing new_string"` — accept `.string` of any length. Implement this so empty replacements work.

- [ ] **Step 3: Add a test for local edit**

```zig
test "edit_file applies a unique replacement to a local file" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "e.txt", .data = "alpha\nbeta\ngamma\n" });
    const abs = try tmp.dir.realpathAlloc(a, "e.txt");
    defer a.free(abs);

    var ctx = try testToolContext(a);
    defer ctx.deinit();
    ctx.value.settings.permission = .full;
    const out = try editFileTool(&ctx.value, abs, "beta", "BETA", false, null);
    defer a.free(out);

    const after = try tmp.dir.readFileAlloc(a, "e.txt", 1024);
    defer a.free(after);
    try std.testing.expectEqualStrings("alpha\nBETA\ngamma\n", after);
}
```

- [ ] **Step 4: Run the full suite**

Run: `zig build test-full`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/ai_chat_tools.zig
git commit -m "feat(agent): edit_file tool (local + remote SSH) with diff"
```

---

## Task 13: Register tool schemas

**Files:**
- Modify: `src/ai_chat_protocol.zig`

- [ ] **Step 1: Add the three `emit` calls in `forEachToolSpec`**

In `src/ai_chat_protocol.zig`, inside `forEachToolSpec`, after the `terminal_repl_exec` emit (near line 664), add:

```zig
    try emit(ctx, "read_file", "Read a local or remote text file. Returns numbered lines. Set surface_id to an open SSH terminal surface to read on that remote host; omit it (or use a local surface) for the local filesystem. Relative paths resolve against the agent working directory. Use offset/limit to read a line range of a large file.", "{\"path\":{\"type\":\"string\",\"description\":\"File path. Absolute, or relative to the working directory.\"},\"surface_id\":{\"type\":\"string\",\"description\":\"Optional SSH surface id (from terminal_list) to read the file on that remote host. Omit for local.\"},\"offset\":{\"type\":\"integer\",\"description\":\"Optional 1-based first line to return.\"},\"limit\":{\"type\":\"integer\",\"description\":\"Optional maximum number of lines to return.\"}}");
    try emit(ctx, "write_file", "Create or overwrite a local or remote text file with exact content. Shows a diff and (unless permission is full) asks for approval. Set surface_id to an open SSH terminal surface to write on that remote host; omit for local. Relative paths resolve against the agent working directory.", "{\"path\":{\"type\":\"string\",\"description\":\"File path. Absolute, or relative to the working directory.\"},\"content\":{\"type\":\"string\",\"description\":\"Full file content to write.\"},\"surface_id\":{\"type\":\"string\",\"description\":\"Optional SSH surface id to write on that remote host. Omit for local.\"}}");
    try emit(ctx, "edit_file", "Replace an exact unique string in a local or remote text file. old_string must match exactly and be unique unless replace_all is true. Shows a diff and (unless permission is full) asks for approval. Set surface_id to an open SSH terminal surface to edit on that remote host; omit for local.", "{\"path\":{\"type\":\"string\",\"description\":\"File path. Absolute, or relative to the working directory.\"},\"old_string\":{\"type\":\"string\",\"description\":\"Exact text to replace. Must be unique unless replace_all is true.\"},\"new_string\":{\"type\":\"string\",\"description\":\"Replacement text. May be empty to delete.\"},\"replace_all\":{\"type\":\"boolean\",\"description\":\"Replace every occurrence instead of requiring a unique match.\"},\"surface_id\":{\"type\":\"string\",\"description\":\"Optional SSH surface id to edit on that remote host. Omit for local.\"}}");
```

- [ ] **Step 2: Add a schema-presence test**

Find an existing tools-JSON test in `src/ai_chat_protocol.zig` (e.g. near line 1411 `"terminal_repl_exec schema documents control keys"`) to see how the tools JSON is built, then add (mirror the existing test's setup for building the OpenAI/Anthropic tools JSON; reuse its helper):

```zig
test "file-edit tools appear in the tool schema" {
    const a = std.testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(a);
    try appendToolSchemas(a, &out);
    const json = out.items;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"read_file\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"write_file\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"edit_file\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"replace_all\"") != null);
}
```

> If `appendToolSchemas` requires a leading `,"tools":[` (it prepends that), assert on the substrings only (as above) rather than exact JSON.

- [ ] **Step 3: Run the full suite**

Run: `zig build test-full`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add src/ai_chat_protocol.zig
git commit -m "feat(agent): register read_file/write_file/edit_file schemas"
```

---

## Task 14: Prompt + docs

**Files:**
- Modify: `src/prompt.md`
- Modify: `src/wispterm_docs.zig` (and the `docs/*.md` it embeds)
- Modify: `wiki/*.md` (matching the AI-agent topic)

- [ ] **Step 1: Add guidance to `src/prompt.md`**

Add a short paragraph in the tools/usage area of `src/prompt.md`:

```md
### File editing

Prefer the dedicated file tools over shell `cat`/`sed`/here-docs for reading and
editing files:

- `read_file` to inspect a file (numbered lines; use `offset`/`limit` for large files).
- `write_file` to create or fully overwrite a file.
- `edit_file` to replace an exact, unique string (set `replace_all` for every occurrence).

For files on a remote SSH server, pass `surface_id` of the open SSH terminal
(from `terminal_list`); the edit runs on that host. Omit `surface_id` for local
files (relative paths resolve against the working directory). Writes and edits
show a diff and may ask for approval.
```

- [ ] **Step 2: Update the in-app AI-agent doc topic**

Find the AI-agent topic embedded by `src/wispterm_docs.zig` (search for `@embedFile` of a `docs/*.md` AI topic). Add the same three-tool description to that `docs/*.md` file, and mirror it into the matching `wiki/*.md` page (per repo convention: keep `docs/` and `wiki/` in sync — see project memory).

- [ ] **Step 3: Run the full suite (embed/string tests in test_main)**

Run: `zig build test-full`
Expected: PASS (the `ai_chat_tools.zig`/prompt embed assertions in `test_main.zig` still hold).

- [ ] **Step 4: Commit**

```bash
git add src/prompt.md src/wispterm_docs.zig docs/ wiki/
git commit -m "docs(agent): document read_file/write_file/edit_file tools"
```

---

## Task 15: Final verification

**Files:** none (verification only)

- [ ] **Step 1: Build**

Run: `zig build`
Expected: builds clean (exit 0).

- [ ] **Step 2: Fast suite**

Run: `zig build test`
Expected: PASS (exit 0).

- [ ] **Step 3: Full suite**

Run: `zig build test-full`
Expected: PASS (exit 0; 0 failed).

- [ ] **Step 4: Windows cross-compile sanity (matches repo CI target)**

Run: `zig build -Dtarget=x86_64-windows-gnu`
Expected: builds (the file tools are POSIX-leaning but compile; remote SSH path uses existing `scp.zig` which already cross-compiles).

> If the Windows build surfaces a POSIX-only API in the new code (e.g. a `std.fs` call), guard or adjust it; the existing tools already handle platform differences via `platform/*` — follow that pattern.

- [ ] **Step 5: Manual GUI smoke (record as pending if no GUI backend)**

Launch the app, open the Copilot/AI chat, and try: `read_file` on a local file, `edit_file` a unique string (observe the diff in the transcript + approval card), then connect an SSH tab and `read_file`/`edit_file` a remote file using its `surface_id`. Record GUI verification status in the project memory note.

---

## Self-Review notes

- **Spec coverage:** trio tools (Tasks 10-12), surface_id remote (Tasks 6/8 + remote branches), access guard reuse (Task 9, `approvalRequiredForGate`), diff-in-transcript + compact card (Tasks 7/11/12 via `emitNote` + `requestApproval`), schemas (Task 13), prompt/docs (Task 14). All spec sections map to a task.
- **Deliberate deviation from spec wording:** the spec said "deny-list still blocks in full mode." To stay consistent with the existing command tools and issue #143 (`full` = truly no prompts), file tools use the same `approvalRequiredForGate` mapping, so `full` does not prompt or block. Deny-list enforcement applies in `confirm`/`auto`. This keeps one permission model across all tools. Flag to the user during review if strict deny-in-full is required (would need a small special-case before the gate).
- **Type consistency:** `agent_file_edit.EditOutcome{new_content, occurrences}`, `applyEdit` error set `{EmptyOld, NotFound, NotUnique}`, `AccessGate{dangerous, blacklisted, force, skip, matched}`, `ToolHost.sshConnectionForSurface: ?*const fn(*anyopaque, []const u8) ?SshConnection`, `ToolContext.note`/`emitNote`/`sshConnectionForSurface` used consistently across tasks.
- **Open implementer checks (noted inline, not placeholders):** the exact `Surface.remote_id` comparison in Task 8 (mirror `makeAgentToolSurface`); the test ToolContext factory name in Tasks 9-12 (reuse the file's existing one); empty-`new_string` handling in Task 12.
