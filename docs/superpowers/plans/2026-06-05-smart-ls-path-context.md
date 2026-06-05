# Smart `ls` Path Context for Ctrl+Click — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a clicked terminal token is a bare filename, infer the directory prefix from the nearest preceding `ls <dir>/` command line and prepend it before path resolution, so ctrl+click previews/downloads of `ls <dir>/` output resolve to the right file.

**Architecture:** A new pure module `src/input/ls_path_context.zig` holds all logic (command-line parsing, upward viewport scan over a generic grid, and the bare-filename prefix-join gate) so it is unit-testable without a `Surface`. The resolver `resolveTerminalPreviewPath` (in `src/input/preview_source.zig`) gains an optional `ls_prefix` parameter and applies the join through the pure module. `src/input.zig` computes the prefix from the live grid at click time and threads it through; the unrelated `html_server.zig` caller passes `null`.

**Tech Stack:** Zig 0.15.2. Fast tests: `zig build test`. Full suite: `zig build test-full`.

Spec: `docs/superpowers/specs/2026-06-05-smart-ls-path-context-design.md`.

---

## File Structure

- **Create** `src/input/ls_path_context.zig` — pure logic: `parseLsDirArg`, `inferPrefixForClick` (+ private `encodeRow`), `isBareRelativeFilename`, `applyLsPrefix`. No `Surface`/terminal dependency; generic over a grid reader. All unit tests live here.
- **Modify** `src/test_fast.zig` — register the new module so its tests run in the fast suite.
- **Modify** `src/input/preview_source.zig` — `resolveTerminalPreviewPath` gains `ls_prefix: ?[]const u8` and calls `ls_path_context.applyLsPrefix`.
- **Modify** `src/input.zig` — import `ls_path_context`, add `lsPrefixForCell` helper, update the two ctrl+click call sites to compute and pass the prefix.
- **Modify** `src/html_server.zig` — pass `null` for the new parameter (no click context).

---

## Task 1: `parseLsDirArg` — parse a command line into a directory prefix

**Files:**
- Create: `src/input/ls_path_context.zig`
- Modify: `src/test_fast.zig`

- [ ] **Step 1: Create the module with `parseLsDirArg` and its tests**

Create `src/input/ls_path_context.zig` with this content:

```zig
//! Smart path context for ctrl+click: infer a directory prefix from a nearby
//! `ls <dir>/` command line so bare-filename clicks resolve to the right file.
//! Pure logic only — no terminal/Surface dependency — so it is unit-testable.

const std = @import("std");

/// Command names whose single trailing-`/` argument we treat as a path prefix.
const ls_commands = [_][]const u8{ "ls", "ll", "la", "l", "dir" };

fn isLsCommand(tok: []const u8) bool {
    for (ls_commands) |cmd| {
        if (std.mem.eql(u8, tok, cmd)) return true;
    }
    return false;
}

/// If `line` is an `ls`-family command with exactly one directory argument
/// (a non-flag token ending in `/`), return that directory (a slice into
/// `line`). Returns null for zero args, multiple non-flag args, a sole
/// argument not ending in `/`, or a non-ls command. The command token may be
/// preceded by an arbitrary prompt prefix.
pub fn parseLsDirArg(line: []const u8) ?[]const u8 {
    var it = std.mem.tokenizeAny(u8, line, " \t");

    var found_cmd = false;
    while (it.next()) |tok| {
        if (isLsCommand(tok)) {
            found_cmd = true;
            break;
        }
    }
    if (!found_cmd) return null;

    var dir: ?[]const u8 = null;
    while (it.next()) |tok| {
        if (tok.len > 0 and tok[0] == '-') continue; // flag
        if (dir != null) return null; // >1 non-flag arg → ambiguous
        dir = tok;
    }

    const d = dir orelse return null; // ls of CWD, no dir arg
    if (d.len == 0 or d[d.len - 1] != '/') return null; // must be a directory
    return d;
}

test "parseLsDirArg: ls with a trailing-slash dir" {
    try std.testing.expectEqualStrings("Ath/Ph_SE/", parseLsDirArg("ls Ath/Ph_SE/").?);
}

test "parseLsDirArg: tolerates a prompt prefix" {
    try std.testing.expectEqualStrings("Ath/Ph_SE/", parseLsDirArg("$ ls Ath/Ph_SE/").?);
    try std.testing.expectEqualStrings("data/", parseLsDirArg("me@box:~/proj$ ls data/").?);
}

test "parseLsDirArg: skips flags" {
    try std.testing.expectEqualStrings("Ath/", parseLsDirArg("ls -la Ath/").?);
    try std.testing.expectEqualStrings("Ath/", parseLsDirArg("ls --color=auto Ath/").?);
}

test "parseLsDirArg: accepts ls-family aliases" {
    try std.testing.expectEqualStrings("d/", parseLsDirArg("ll d/").?);
    try std.testing.expectEqualStrings("d/", parseLsDirArg("la d/").?);
    try std.testing.expectEqualStrings("d/", parseLsDirArg("l d/").?);
    try std.testing.expectEqualStrings("d/", parseLsDirArg("dir d/").?);
}

test "parseLsDirArg: rejects non-ls and lookalike commands" {
    try std.testing.expect(parseLsDirArg("lsblk d/") == null);
    try std.testing.expect(parseLsDirArg("cat foo.txt") == null);
    try std.testing.expect(parseLsDirArg("~/tools/ls d/") == null);
}

test "parseLsDirArg: rejects zero, multiple, and non-dir args" {
    try std.testing.expect(parseLsDirArg("ls") == null);
    try std.testing.expect(parseLsDirArg("ls -la") == null);
    try std.testing.expect(parseLsDirArg("ls A/ B/") == null);
    try std.testing.expect(parseLsDirArg("ls foo.txt") == null);
    try std.testing.expect(parseLsDirArg("ls Ath") == null);
}
```

- [ ] **Step 2: Register the module in the fast test suite**

In `src/test_fast.zig`, add the import next to the other `input/` modules (after the `preview_path.zig` line):

```zig
    _ = @import("input/preview_path.zig");
    _ = @import("input/ls_path_context.zig");
```

- [ ] **Step 3: Run the fast suite to verify the new tests pass**

Run: `zig build test`
Expected: PASS (exit 0), including the `parseLsDirArg` tests. If a test fails or the build errors, fix before continuing.

- [ ] **Step 4: Commit**

```bash
git add src/input/ls_path_context.zig src/test_fast.zig
git commit -m "feat: parse ls command line into a directory prefix

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: `inferPrefixForClick` — scan upward over the grid for the nearest match

**Files:**
- Modify: `src/input/ls_path_context.zig`

- [ ] **Step 1: Add `encodeRow`, `inferPrefixForClick`, and fake-grid tests**

Append to `src/input/ls_path_context.zig` (after `parseLsDirArg`, before the existing tests is fine — or at end; placement does not matter as long as it compiles):

```zig
/// Encode one grid row into UTF-8 bytes in `buf`. Empty cells (codepoint 0)
/// become spaces so tokenization sees word boundaries. Truncates at `buf` len.
fn encodeRow(grid: anytype, row: usize, buf: []u8) []const u8 {
    const cols = grid.colCount(row);
    var n: usize = 0;
    var col: usize = 0;
    while (col < cols) : (col += 1) {
        var cp = grid.codepoint(row, col);
        if (cp == 0) cp = ' ';
        var tmp: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &tmp) catch continue;
        if (n + len > buf.len) break;
        @memcpy(buf[n .. n + len], tmp[0..len]);
        n += len;
    }
    return buf[0..n];
}

/// Scan upward from `click_row` (bounded to the grid) for the nearest line that
/// parses as an `ls <dir>/` command. On a hit, copy the directory into
/// `out_buf` and return it; otherwise null. `grid` must expose
/// `rowCount() usize`, `colCount(row) usize`, and `codepoint(row, col) u21`.
pub fn inferPrefixForClick(grid: anytype, click_row: usize, out_buf: []u8) ?[]const u8 {
    const count = grid.rowCount();
    if (count == 0) return null;
    var row = if (click_row >= count) count - 1 else click_row;
    var line_buf: [1024]u8 = undefined;
    while (true) {
        const line = encodeRow(grid, row, &line_buf);
        if (parseLsDirArg(line)) |dir| {
            if (dir.len == 0 or dir.len > out_buf.len) return null;
            @memcpy(out_buf[0..dir.len], dir);
            return out_buf[0..dir.len];
        }
        if (row == 0) break;
        row -= 1;
    }
    return null;
}

/// Test-only grid backed by ASCII rows (index 0 = top row).
const FakeGrid = struct {
    rows: []const []const u8,

    fn rowCount(self: FakeGrid) usize {
        return self.rows.len;
    }
    fn colCount(self: FakeGrid, row: usize) usize {
        return self.rows[row].len;
    }
    fn codepoint(self: FakeGrid, row: usize, col: usize) u21 {
        return self.rows[row][col];
    }
};

test "inferPrefixForClick: finds the ls command above the clicked row" {
    const grid = FakeGrid{ .rows = &.{
        "$ ls Ath/Ph_SE/",
        "cluster_resolution_summary.tsv",
        "summary.txt",
    } };
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("Ath/Ph_SE/", inferPrefixForClick(grid, 2, &buf).?);
}

test "inferPrefixForClick: picks the nearest ls when several exist" {
    const grid = FakeGrid{ .rows = &.{
        "$ ls first/",
        "a.txt",
        "$ ls second/",
        "b.txt",
    } };
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("second/", inferPrefixForClick(grid, 3, &buf).?);
}

test "inferPrefixForClick: no ls above returns null" {
    const grid = FakeGrid{ .rows = &.{
        "$ cat notes.txt",
        "some output",
    } };
    var buf: [256]u8 = undefined;
    try std.testing.expect(inferPrefixForClick(grid, 1, &buf) == null);
}

test "inferPrefixForClick: empty grid returns null" {
    const grid = FakeGrid{ .rows = &.{} };
    var buf: [256]u8 = undefined;
    try std.testing.expect(inferPrefixForClick(grid, 0, &buf) == null);
}
```

- [ ] **Step 2: Run the fast suite to verify the new tests pass**

Run: `zig build test`
Expected: PASS (exit 0), including the four `inferPrefixForClick` tests.

- [ ] **Step 3: Commit**

```bash
git add src/input/ls_path_context.zig
git commit -m "feat: scan terminal grid upward for nearest ls dir prefix

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: `isBareRelativeFilename` + `applyLsPrefix` — the join gate

**Files:**
- Modify: `src/input/ls_path_context.zig`

- [ ] **Step 1: Add the gate functions and tests**

Append to `src/input/ls_path_context.zig`:

```zig
/// True when `path` is a plain filename with no directory component: not
/// absolute, not `~`-rooted, no `/` or `\`, and not a `X:` Windows drive path.
pub fn isBareRelativeFilename(path: []const u8) bool {
    if (path.len == 0) return false;
    if (path[0] == '/' or path[0] == '~') return false;
    if (path.len >= 2 and path[1] == ':') return false; // windows drive letter
    for (path) |c| {
        if (c == '/' or c == '\\') return false;
    }
    return true;
}

/// When `ls_prefix` is present and `path` is a bare filename, return an
/// allocator-owned `prefix ++ path`. Returns null to mean "use `path` as-is"
/// (no prefix, or the token is already a path). Caller frees a non-null result.
pub fn applyLsPrefix(allocator: std.mem.Allocator, path: []const u8, ls_prefix: ?[]const u8) !?[]u8 {
    const pfx = ls_prefix orelse return null;
    if (!isBareRelativeFilename(path)) return null;
    return try std.fmt.allocPrint(allocator, "{s}{s}", .{ pfx, path });
}

test "isBareRelativeFilename: accepts plain names, rejects pathed tokens" {
    try std.testing.expect(isBareRelativeFilename("cluster_resolution_summary.tsv"));
    try std.testing.expect(!isBareRelativeFilename("Ath/Ph_SE/x.tsv"));
    try std.testing.expect(!isBareRelativeFilename("/abs/x.tsv"));
    try std.testing.expect(!isBareRelativeFilename("~/x.tsv"));
    try std.testing.expect(!isBareRelativeFilename("C:/x.tsv"));
    try std.testing.expect(!isBareRelativeFilename("dir\\x.tsv"));
    try std.testing.expect(!isBareRelativeFilename(""));
}

test "applyLsPrefix: joins prefix onto a bare filename" {
    const allocator = std.testing.allocator;
    const joined = (try applyLsPrefix(allocator, "x.tsv", "Ath/Ph_SE/")).?;
    defer allocator.free(joined);
    try std.testing.expectEqualStrings("Ath/Ph_SE/x.tsv", joined);
}

test "applyLsPrefix: null prefix or already-pathed token yields null" {
    const allocator = std.testing.allocator;
    try std.testing.expect((try applyLsPrefix(allocator, "x.tsv", null)) == null);
    try std.testing.expect((try applyLsPrefix(allocator, "sub/x.tsv", "Ath/")) == null);
    try std.testing.expect((try applyLsPrefix(allocator, "/abs/x.tsv", "Ath/")) == null);
}
```

- [ ] **Step 2: Run the fast suite to verify the new tests pass**

Run: `zig build test`
Expected: PASS (exit 0), including the `isBareRelativeFilename` and `applyLsPrefix` tests.

- [ ] **Step 3: Commit**

```bash
git add src/input/ls_path_context.zig
git commit -m "feat: gate ls prefix join to bare relative filenames

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: Wire the prefix into resolution and the ctrl+click call sites

**Files:**
- Modify: `src/input/preview_source.zig` (`resolveTerminalPreviewPath`)
- Modify: `src/input.zig` (import, `lsPrefixForCell`, two call sites)
- Modify: `src/html_server.zig` (one call site)

- [ ] **Step 1: Add the `ls_path_context` import to `preview_source.zig`**

In `src/input/preview_source.zig`, add to the import block near the top (after the `preview_path` import on line 10):

```zig
const preview_path = @import("preview_path.zig");
const ls_path_context = @import("ls_path_context.zig");
```

- [ ] **Step 2: Change `resolveTerminalPreviewPath` to take and apply `ls_prefix`**

In `src/input/preview_source.zig`, replace the whole `resolveTerminalPreviewPath` function (currently starting at line 164) with:

```zig
pub fn resolveTerminalPreviewPath(allocator: std.mem.Allocator, surface: *Surface, path: []const u8, ls_prefix: ?[]const u8) ![]u8 {
    const joined = try ls_path_context.applyLsPrefix(allocator, path, ls_prefix);
    defer if (joined) |j| allocator.free(j);
    const eff = joined orelse path;

    return switch (surface.launch_kind) {
        .wsl => try resolveUnixTerminalPath(allocator, surface.getCwd() orelse "~", eff, false),
        .ssh => try resolveUnixTerminalPath(allocator, surface.getCwd(), eff, true),
        .local => blk: {
            if (std.fs.path.isAbsolute(eff) or (eff.len >= 2 and eff[1] == ':')) {
                break :blk try allocator.dupe(u8, eff);
            }
            // Resolve relative to the shell's CURRENT cwd, not its launch cwd:
            // the user may have `cd`'d, and shells like zsh don't emit OSC 7,
            // so we fall back to a live process-cwd query (see dupeCurrentCwd).
            const cwd = surface.dupeCurrentCwd(allocator) orelse {
                break :blk try allocator.dupe(u8, eff);
            };
            defer allocator.free(cwd);
            break :blk try std.fs.path.join(allocator, &.{ cwd, eff });
        },
    };
}
```

- [ ] **Step 3: Add the `ls_path_context` import and `lsPrefixForCell` helper to `input.zig`**

In `src/input.zig`, add the import near the other input-submodule imports (the `preview_source` import is on line 50):

```zig
const preview_source = @import("input/preview_source.zig");
const ls_path_context = @import("input/ls_path_context.zig");
```

Then add this helper immediately above `fn openPreviewPanelForCell` (line 2786). It reuses the existing `TerminalTokenGrid` (defined at line 2341) under the render-state mutex:

```zig
fn lsPrefixForCell(surface: *Surface, cell_pos: CellPos, out_buf: []u8) ?[]const u8 {
    const cols = @as(usize, @intCast(surface.size.grid.cols));
    const rows = @as(usize, @intCast(surface.size.grid.rows));
    if (cols == 0 or rows == 0 or cell_pos.row >= rows) return null;

    surface.render_state.mutex.lock();
    defer surface.render_state.mutex.unlock();

    const grid = TerminalTokenGrid{ .surface = surface, .rows = rows, .cols = cols };
    return ls_path_context.inferPrefixForClick(grid, cell_pos.row, out_buf);
}
```

- [ ] **Step 4: Update the preview call site in `openPreviewPanelForCell`**

In `src/input.zig`, in `openPreviewPanelForCell`, after the line `defer allocator.free(path);` (line 2789) insert:

```zig
    defer allocator.free(path);

    var ls_prefix_buf: [256]u8 = undefined;
    const ls_prefix = lsPrefixForCell(surface, cell_pos, &ls_prefix_buf);
```

Then change the resolve call (line 2792) from:

```zig
        const resolved_path = resolveTerminalPreviewPath(allocator, surface, path) catch {
```

to:

```zig
        const resolved_path = resolveTerminalPreviewPath(allocator, surface, path, ls_prefix) catch {
```

- [ ] **Step 5: Update the download call site in `downloadTerminalFileAtCell`**

In `src/input.zig`, in `downloadTerminalFileAtCell`, after its `defer allocator.free(path);` (line 2820) insert:

```zig
    defer allocator.free(path);

    var ls_prefix_buf: [256]u8 = undefined;
    const ls_prefix = lsPrefixForCell(surface, cell_pos, &ls_prefix_buf);
```

Then change the resolve call (line 2822) from:

```zig
    const resolved_path = resolveTerminalPreviewPath(allocator, surface, path) catch |err| {
```

to:

```zig
    const resolved_path = resolveTerminalPreviewPath(allocator, surface, path, ls_prefix) catch |err| {
```

- [ ] **Step 6: Update the `html_server.zig` call site to pass `null`**

In `src/html_server.zig`, in `openForSurface`, change the resolve call (line 124) from:

```zig
    const resolved = preview_source.resolveTerminalPreviewPath(allocator, surface, path) catch |err| {
```

to:

```zig
    const resolved = preview_source.resolveTerminalPreviewPath(allocator, surface, path, null) catch |err| {
```

- [ ] **Step 7: Build and run the full suite**

Run: `zig build test-full`
Expected: PASS (exit 0), 0 failed. This compiles the full app graph (covering `input.zig`, `preview_source.zig`, `html_server.zig`) and confirms the signature change is consistent across all three call sites.

Also run the fast suite to confirm nothing regressed:

Run: `zig build test`
Expected: PASS (exit 0).

- [ ] **Step 8: Commit**

```bash
git add src/input/preview_source.zig src/input.zig src/html_server.zig
git commit -m "feat: resolve ls-listed bare filenames via inferred dir prefix

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review notes

- **Spec coverage:** parsing rules → Task 1; upward viewport scan → Task 2; bare-filename gate + join → Task 3; wiring into `resolveTerminalPreviewPath` with both preview and SSH-download benefiting, local/WSL/SSH uniform → Task 4. The "no existence check / viewport-only / heuristic" trade-offs fall out of the design (no extra code). All three callers (incl. `html_server.zig`, found during planning) are updated.
- **Type consistency:** `parseLsDirArg(line) ?[]const u8`, `inferPrefixForClick(grid, click_row, out_buf) ?[]const u8`, `isBareRelativeFilename(path) bool`, `applyLsPrefix(allocator, path, ls_prefix) !?[]u8`, `resolveTerminalPreviewPath(allocator, surface, path, ls_prefix)` are used identically everywhere they appear.
- **GUI note:** As with prior preview work, GUI verification (Windows/WSL) is manual and out of scope for these automated steps; flag it as pending after merge.

## Known limitations (accepted for v1, from the spec)

- Quoted directory args containing spaces (`ls "My Dir/"`) are not handled — tokenization splits on whitespace.
- The `ls` command must still be within the visible viewport; if it scrolled off, resolution falls back to the current CWD-relative behavior.
- Without OSC 133 shell integration, an unrecognized intervening command could let the scan reach an earlier `ls`. Low-probability misfire; fails gracefully.
