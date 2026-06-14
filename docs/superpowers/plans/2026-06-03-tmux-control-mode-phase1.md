# tmux Control Mode — Phase 1 (Protocol Parsers) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the two pure, `std`-only modules that decode the tmux control-mode (`tmux -CC`) wire protocol — `src/tmux/control.zig` (line-protocol notification parser) and `src/tmux/layout.zig` (layout-string tree parser) — fully unit-tested under the fast suite, with no UI wiring yet.

**Architecture:** `control.zig` is a byte-fed state machine: `Parser.put(byte)` returns a `Notification` when a complete control line (or `%begin/%end` block) parses. `layout.zig` is a recursive-descent parser turning a tmux layout string (`80x24,0,0{40x24,0,0,1,39x24,41,0,2}`) into a `Node` tree. Both are side-effect-free and depend only on `std`, so they live in the fast test suite (`zig build test`). Later phases consume them; this phase ships a tested decoder library.

**Tech Stack:** Zig (this repo tracks a recent 0.15-dev `std`: `std.ArrayListUnmanaged` with `.empty`, `std.mem.splitScalar`, `std.heap.ArenaAllocator`). In-file `test { ... }` blocks, registered in `src/test_fast.zig`, run by `zig build test`.

**Reference:** The design spec is `docs/superpowers/specs/2026-06-03-tmux-control-mode-integration-design.md`. The wire format was cross-checked against the (build-disabled) reference parser in the `ghostty-vt` dependency at `src/terminal/tmux/{control,layout}.zig`.

---

## File Structure

| File | Responsibility |
|---|---|
| `src/tmux/control.zig` | NEW. `Notification` union + `Parser` state machine (`init`/`put`/`deinit`) + pure `unescape` helper for octal-escaped `%output` data. Imports only `std`. |
| `src/tmux/layout.zig` | NEW. `Node`/`Dir`/`Layout` types + `parse(gpa, str)` recursive-descent parser (arena-owned tree) + `checksum`. Imports only `std`. |
| `src/tmux/protocol_test.zig` | NEW. Cross-module test: a `%layout-change` notification's layout string flows from `control.Parser` into `layout.parse`. Keeps `control`/`layout` independent of each other. |
| `src/test_fast.zig` | MODIFY. Register the three new files in the `test { ... }` block so `zig build test` runs them. |

Boundary rule enforced by tests: `control.zig` and `layout.zig` never import each other or anything but `std`; the only place they meet is `protocol_test.zig`.

---

## Task 1: control.zig scaffold + `%window-add`

**Files:**
- Create: `src/tmux/control.zig`
- Modify: `src/test_fast.zig` (register import)

- [ ] **Step 1: Create `src/tmux/control.zig` with the state machine and the first notification + its test**

```zig
//! Hand-rolled tmux control-mode (`tmux -CC`) line-protocol parser.
//! Pure: depends only on `std`. Feed server->client bytes via `put`; receive a
//! `Notification` when a complete control line (or `%begin/%end` block) parses.
//!
//! Lifetime: slices inside a returned Notification (e.g. `output.data`,
//! `window_renamed.name`, `block_end`) point into parser-owned scratch and are
//! valid ONLY until the next `put` call. Consume them immediately.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Notification = union(enum) {
    /// Control mode began. Synthesized by the caller on DCS 1000p; never
    /// produced by `put`. Present so downstream code has one event type.
    enter,
    /// Control mode ended (`%exit`).
    exit,
    /// Raw (still octal-escaped) output bytes for a pane. Run `unescape` before
    /// feeding a terminal.
    output: struct { pane_id: usize, data: []const u8 },
    /// A `%begin`/`%end` command-reply block finished; body is the raw output.
    block_end: []const u8,
    /// A `%begin`/`%error` command-reply block finished with an error.
    block_err: []const u8,
    /// The layout of a window changed. `layout` is the tmux layout string.
    layout_change: struct { window_id: usize, layout: []const u8 },
    /// A window was linked into the session.
    window_add: struct { window_id: usize },
    /// A window was renamed.
    window_renamed: struct { window_id: usize, name: []const u8 },
    /// A window closed / was unlinked.
    window_close: struct { window_id: usize },
    /// The active pane within a window changed.
    window_pane_changed: struct { window_id: usize, pane_id: usize },
    /// The attached session changed.
    session_changed: struct { session_id: usize, name: []const u8 },
    /// Sessions were created or destroyed.
    sessions_changed,
};

pub const Parser = struct {
    alloc: Allocator,
    line: std.ArrayListUnmanaged(u8) = .empty,
    line_done: bool = false,

    pub fn init(alloc: Allocator) Parser {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Parser) void {
        self.line.deinit(self.alloc);
    }

    /// Feed one byte. Returns a Notification when a control line completes.
    pub fn put(self: *Parser, byte: u8) Allocator.Error!?Notification {
        if (self.line_done) {
            self.line.clearRetainingCapacity();
            self.line_done = false;
        }
        if (byte != '\n') {
            try self.line.append(self.alloc, byte);
            return null;
        }
        var line = self.line.items;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        self.line_done = true;
        return processLine(line);
    }

    fn processLine(line: []const u8) ?Notification {
        if (line.len == 0 or line[0] != '%') return null;
        const sp = std.mem.indexOfScalar(u8, line, ' ') orelse line.len;
        const cmd = line[0..sp];

        if (std.mem.eql(u8, cmd, "%window-add")) return parseWindowAdd(line);
        return null;
    }
};

fn parseWindowAdd(line: []const u8) ?Notification {
    const prefix = "%window-add ";
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    const tok = std.mem.trimRight(u8, line[prefix.len..], " ");
    if (tok.len < 2 or tok[0] != '@') return null;
    const id = std.fmt.parseInt(usize, tok[1..], 10) catch return null;
    return .{ .window_add = .{ .window_id = id } };
}

/// Test helper: feed an entire string, returning the last Notification produced.
/// Inputs must end with `\n`; returned slices stay valid until the next `put`.
fn feed(p: *Parser, s: []const u8) !?Notification {
    var result: ?Notification = null;
    for (s) |b| {
        if (try p.put(b)) |n| result = n;
    }
    return result;
}

test "non-control lines are ignored" {
    var p = Parser.init(std.testing.allocator);
    defer p.deinit();
    try std.testing.expectEqual(@as(?Notification, null), try feed(&p, "hello world\n"));
}

test "parses %window-add" {
    var p = Parser.init(std.testing.allocator);
    defer p.deinit();
    const n = (try feed(&p, "%window-add @14\n")).?;
    try std.testing.expectEqual(@as(usize, 14), n.window_add.window_id);
}
```

Then register it in `src/test_fast.zig` — add this line inside the `test { ... }` block (next to the other `_ = @import(...)` lines):

```zig
    _ = @import("tmux/control.zig");
```

- [ ] **Step 2: Run the suite to verify the new tests pass**

Run: `zig build test`
Expected: PASS, exit 0. (The two tests in `control.zig` run alongside the existing fast suite.)

- [ ] **Step 3: Commit**

```bash
git add src/tmux/control.zig src/test_fast.zig
git commit -m "feat(tmux): control-mode parser scaffold + %window-add"
```

---

## Task 2: window-renamed, window-close, window-pane-changed

**Files:**
- Modify: `src/tmux/control.zig`

- [ ] **Step 1: Add the failing tests** (append to the `test` blocks in `control.zig`)

```zig
test "parses %window-renamed (name may contain spaces)" {
    var p = Parser.init(std.testing.allocator);
    defer p.deinit();
    const n = (try feed(&p, "%window-renamed @42 my project\n")).?;
    try std.testing.expectEqual(@as(usize, 42), n.window_renamed.window_id);
    try std.testing.expectEqualStrings("my project", n.window_renamed.name);
}

test "parses %window-close" {
    var p = Parser.init(std.testing.allocator);
    defer p.deinit();
    const n = (try feed(&p, "%window-close @7\n")).?;
    try std.testing.expectEqual(@as(usize, 7), n.window_close.window_id);
}

test "parses %window-pane-changed" {
    var p = Parser.init(std.testing.allocator);
    defer p.deinit();
    const n = (try feed(&p, "%window-pane-changed @42 %2\n")).?;
    try std.testing.expectEqual(@as(usize, 42), n.window_pane_changed.window_id);
    try std.testing.expectEqual(@as(usize, 2), n.window_pane_changed.pane_id);
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `zig build test`
Expected: FAIL — these three lines currently parse to `null` (the `.?` unwrap panics / assertion fails).

- [ ] **Step 3: Add the dispatch branches and parsers**

In `processLine`, add before `return null;`:

```zig
        if (std.mem.eql(u8, cmd, "%window-renamed")) return parseWindowRenamed(line);
        if (std.mem.eql(u8, cmd, "%window-close")) return parseWindowClose(line);
        if (std.mem.eql(u8, cmd, "%window-pane-changed")) return parseWindowPaneChanged(line);
```

And add these free functions (next to `parseWindowAdd`):

```zig
fn parseWindowRenamed(line: []const u8) ?Notification {
    const prefix = "%window-renamed ";
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    var it = std.mem.splitScalar(u8, line[prefix.len..], ' ');
    const id_tok = it.next() orelse return null;
    if (id_tok.len < 2 or id_tok[0] != '@') return null;
    const id = std.fmt.parseInt(usize, id_tok[1..], 10) catch return null;
    return .{ .window_renamed = .{ .window_id = id, .name = it.rest() } };
}

fn parseWindowClose(line: []const u8) ?Notification {
    const prefix = "%window-close ";
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    const tok = std.mem.trimRight(u8, line[prefix.len..], " ");
    if (tok.len < 2 or tok[0] != '@') return null;
    const id = std.fmt.parseInt(usize, tok[1..], 10) catch return null;
    return .{ .window_close = .{ .window_id = id } };
}

fn parseWindowPaneChanged(line: []const u8) ?Notification {
    const prefix = "%window-pane-changed ";
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    var it = std.mem.splitScalar(u8, line[prefix.len..], ' ');
    const win_tok = it.next() orelse return null;
    const pane_tok = it.next() orelse return null;
    if (win_tok.len < 2 or win_tok[0] != '@') return null;
    if (pane_tok.len < 2 or pane_tok[0] != '%') return null;
    const win = std.fmt.parseInt(usize, win_tok[1..], 10) catch return null;
    const pane = std.fmt.parseInt(usize, std.mem.trimRight(u8, pane_tok[1..], " "), 10) catch return null;
    return .{ .window_pane_changed = .{ .window_id = win, .pane_id = pane } };
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `zig build test`
Expected: PASS, exit 0.

- [ ] **Step 5: Commit**

```bash
git add src/tmux/control.zig
git commit -m "feat(tmux): parse window-renamed/close/pane-changed notifications"
```

---

## Task 3: `%output` (raw data + lifetime contract)

**Files:**
- Modify: `src/tmux/control.zig`

- [ ] **Step 1: Add the failing tests**

```zig
test "parses %output keeping the data tail verbatim" {
    var p = Parser.init(std.testing.allocator);
    defer p.deinit();
    const n = (try feed(&p, "%output %42 foo bar baz\n")).?;
    try std.testing.expectEqual(@as(usize, 42), n.output.pane_id);
    try std.testing.expectEqualStrings("foo bar baz", n.output.data);
}

test "%output data is valid until the next put" {
    var p = Parser.init(std.testing.allocator);
    defer p.deinit();
    const n = (try feed(&p, "%output %1 hello\n")).?;
    // Still valid immediately after the producing put.
    try std.testing.expectEqualStrings("hello", n.output.data);
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `zig build test`
Expected: FAIL — `%output` parses to `null` today.

- [ ] **Step 3: Add the dispatch branch and parser**

In `processLine`, add before `return null;`:

```zig
        if (std.mem.eql(u8, cmd, "%output")) return parseOutput(line);
```

Add the parser:

```zig
fn parseOutput(line: []const u8) ?Notification {
    const prefix = "%output ";
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    var rest = line[prefix.len..];
    if (rest.len == 0 or rest[0] != '%') return null;
    rest = rest[1..];
    const sp = std.mem.indexOfScalar(u8, rest, ' ') orelse return null;
    const id = std.fmt.parseInt(usize, rest[0..sp], 10) catch return null;
    return .{ .output = .{ .pane_id = id, .data = rest[sp + 1 ..] } };
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `zig build test`
Expected: PASS, exit 0.

- [ ] **Step 5: Commit**

```bash
git add src/tmux/control.zig
git commit -m "feat(tmux): parse %output notifications (raw data slice)"
```

---

## Task 4: `unescape` (octal + backslash)

tmux escapes non-printable bytes in `%output` as `\ooo` (backslash + exactly three octal digits) and a literal backslash as `\\`. The parser returns raw data; this pure helper decodes it.

**Files:**
- Modify: `src/tmux/control.zig`

- [ ] **Step 1: Add the failing tests**

```zig
test "unescape decodes octal escapes and double-backslash" {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    // \033 = ESC (0x1b), \\ = backslash, plain letters pass through.
    try unescape(std.testing.allocator, &out, "a\\033b\\\\c");
    try std.testing.expectEqualSlices(u8, &.{ 'a', 0x1b, 'b', '\\', 'c' }, out.items);
}

test "unescape leaves a lone trailing backslash literal" {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try unescape(std.testing.allocator, &out, "x\\");
    try std.testing.expectEqualSlices(u8, &.{ 'x', '\\' }, out.items);
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `zig build test`
Expected: FAIL — `unescape` is not defined (compile error: use of undeclared identifier `unescape`).

- [ ] **Step 3: Implement `unescape`**

```zig
/// Octal-unescape tmux `%output` data into `out`. tmux escapes non-printable
/// bytes as `\ooo` (three octal digits) and a literal backslash as `\\`.
pub fn unescape(
    alloc: Allocator,
    out: *std.ArrayListUnmanaged(u8),
    src: []const u8,
) Allocator.Error!void {
    var i: usize = 0;
    while (i < src.len) {
        const c = src[i];
        if (c != '\\') {
            try out.append(alloc, c);
            i += 1;
            continue;
        }
        if (i + 1 < src.len and src[i + 1] == '\\') {
            try out.append(alloc, '\\');
            i += 2;
            continue;
        }
        if (i + 3 < src.len and isOctal(src[i + 1]) and isOctal(src[i + 2]) and isOctal(src[i + 3])) {
            const v: u16 = (@as(u16, src[i + 1] - '0') << 6) |
                (@as(u16, src[i + 2] - '0') << 3) |
                @as(u16, src[i + 3] - '0');
            try out.append(alloc, @intCast(v & 0xFF));
            i += 4;
            continue;
        }
        // Malformed escape: emit the backslash literally.
        try out.append(alloc, '\\');
        i += 1;
    }
}

fn isOctal(c: u8) bool {
    return c >= '0' and c <= '7';
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `zig build test`
Expected: PASS, exit 0.

- [ ] **Step 5: Commit**

```bash
git add src/tmux/control.zig
git commit -m "feat(tmux): octal unescape helper for %output data"
```

---

## Task 5: layout-change, session-changed, sessions-changed, exit

**Files:**
- Modify: `src/tmux/control.zig`

- [ ] **Step 1: Add the failing tests**

```zig
test "parses %layout-change keeping only window id and layout string" {
    var p = Parser.init(std.testing.allocator);
    defer p.deinit();
    const n = (try feed(&p, "%layout-change @2 bd1b,80x24,0,0,1 bd1b,80x24,0,0,1 *\n")).?;
    try std.testing.expectEqual(@as(usize, 2), n.layout_change.window_id);
    try std.testing.expectEqualStrings("bd1b,80x24,0,0,1", n.layout_change.layout);
}

test "parses %session-changed" {
    var p = Parser.init(std.testing.allocator);
    defer p.deinit();
    const n = (try feed(&p, "%session-changed $1 work\n")).?;
    try std.testing.expectEqual(@as(usize, 1), n.session_changed.session_id);
    try std.testing.expectEqualStrings("work", n.session_changed.name);
}

test "parses %sessions-changed and %exit" {
    var p = Parser.init(std.testing.allocator);
    defer p.deinit();
    try std.testing.expect(std.meta.activeTag((try feed(&p, "%sessions-changed\n")).?) == .sessions_changed);
    try std.testing.expect(std.meta.activeTag((try feed(&p, "%exit\n")).?) == .exit);
    try std.testing.expect(std.meta.activeTag((try feed(&p, "%exit server exited\n")).?) == .exit);
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `zig build test`
Expected: FAIL — these four commands parse to `null` today.

- [ ] **Step 3: Add the dispatch branches and parsers**

In `processLine`, add before `return null;`:

```zig
        if (std.mem.eql(u8, cmd, "%layout-change")) return parseLayoutChange(line);
        if (std.mem.eql(u8, cmd, "%session-changed")) return parseSessionChanged(line);
        if (std.mem.eql(u8, cmd, "%sessions-changed")) return .sessions_changed;
        if (std.mem.eql(u8, cmd, "%exit")) return .exit;
```

Add the parsers:

```zig
fn parseLayoutChange(line: []const u8) ?Notification {
    const prefix = "%layout-change ";
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    var it = std.mem.splitScalar(u8, line[prefix.len..], ' ');
    const id_tok = it.next() orelse return null;
    if (id_tok.len < 2 or id_tok[0] != '@') return null;
    const id = std.fmt.parseInt(usize, id_tok[1..], 10) catch return null;
    const layout = it.next() orelse return null;
    return .{ .layout_change = .{ .window_id = id, .layout = layout } };
}

fn parseSessionChanged(line: []const u8) ?Notification {
    const prefix = "%session-changed ";
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    var it = std.mem.splitScalar(u8, line[prefix.len..], ' ');
    const id_tok = it.next() orelse return null;
    if (id_tok.len < 2 or id_tok[0] != '$') return null;
    const id = std.fmt.parseInt(usize, id_tok[1..], 10) catch return null;
    return .{ .session_changed = .{ .session_id = id, .name = it.rest() } };
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `zig build test`
Expected: PASS, exit 0.

- [ ] **Step 5: Commit**

```bash
git add src/tmux/control.zig
git commit -m "feat(tmux): parse layout-change/session-changed/exit notifications"
```

---

## Task 6: `%begin`/`%end`/`%error` command-reply blocks

Command replies (e.g. to `list-windows`, `capture-pane`) arrive between a `%begin` and a matching `%end` (or `%error`). The body lines in between are raw output. This task adds block state to the parser.

**Files:**
- Modify: `src/tmux/control.zig`

- [ ] **Step 1: Add the failing tests**

```zig
test "accumulates a %begin/%end block body" {
    var p = Parser.init(std.testing.allocator);
    defer p.deinit();
    try std.testing.expectEqual(@as(?Notification, null), try feed(&p, "%begin 1 1 1\n"));
    try std.testing.expectEqual(@as(?Notification, null), try feed(&p, "line one\n"));
    const n = (try feed(&p, "line two\n%end 1 1 1\n")).?;
    try std.testing.expectEqualStrings("line one\nline two", n.block_end);
}

test "%error closes a block as block_err" {
    var p = Parser.init(std.testing.allocator);
    defer p.deinit();
    _ = try feed(&p, "%begin 2 2 0\n");
    const n = (try feed(&p, "boom\n%error 2 2 0\n")).?;
    try std.testing.expectEqualStrings("boom", n.block_err);
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `zig build test`
Expected: FAIL — `%begin` is currently unknown, so the block body lines are treated as stray non-control lines and `%end` yields `null`.

- [ ] **Step 3: Add block state**

Add two fields to `Parser` (after `line_done`):

```zig
    block: std.ArrayListUnmanaged(u8) = .empty,
    block_done: bool = false,
    in_block: bool = false,
```

Update `deinit` to also free the block buffer:

```zig
    pub fn deinit(self: *Parser) void {
        self.line.deinit(self.alloc);
        self.block.deinit(self.alloc);
    }
```

In `put`, add a block reset next to the line reset (at the top):

```zig
        if (self.block_done) {
            self.block.clearRetainingCapacity();
            self.block_done = false;
        }
```

Block accumulation needs the allocator, so change `processLine` from a free function into a method and add the block logic at the top. Replace the `return processLine(line);` line in `put` with:

```zig
        return self.processLine(line);
```

And replace the whole `fn processLine(line: []const u8) ?Notification { ... }` with:

```zig
    fn processLine(self: *Parser, line: []const u8) Allocator.Error!?Notification {
        if (self.in_block) {
            if (std.mem.startsWith(u8, line, "%end")) {
                self.in_block = false;
                self.block_done = true;
                return .{ .block_end = self.block.items };
            }
            if (std.mem.startsWith(u8, line, "%error")) {
                self.in_block = false;
                self.block_done = true;
                return .{ .block_err = self.block.items };
            }
            if (self.block.items.len > 0) try self.block.append(self.alloc, '\n');
            try self.block.appendSlice(self.alloc, line);
            return null;
        }

        if (line.len == 0 or line[0] != '%') return null;
        const sp = std.mem.indexOfScalar(u8, line, ' ') orelse line.len;
        const cmd = line[0..sp];

        if (std.mem.eql(u8, cmd, "%begin")) {
            self.block.clearRetainingCapacity();
            self.in_block = true;
            return null;
        }
        if (std.mem.eql(u8, cmd, "%output")) return parseOutput(line);
        if (std.mem.eql(u8, cmd, "%layout-change")) return parseLayoutChange(line);
        if (std.mem.eql(u8, cmd, "%window-add")) return parseWindowAdd(line);
        if (std.mem.eql(u8, cmd, "%window-renamed")) return parseWindowRenamed(line);
        if (std.mem.eql(u8, cmd, "%window-close")) return parseWindowClose(line);
        if (std.mem.eql(u8, cmd, "%window-pane-changed")) return parseWindowPaneChanged(line);
        if (std.mem.eql(u8, cmd, "%session-changed")) return parseSessionChanged(line);
        if (std.mem.eql(u8, cmd, "%sessions-changed")) return .sessions_changed;
        if (std.mem.eql(u8, cmd, "%exit")) return .exit;
        return null;
    }
```

(`put` already does `return self.processLine(line);`, which now returns `Allocator.Error!?Notification` — the `try`/`return` in `put` already propagate it.)

- [ ] **Step 4: Run to verify they pass**

Run: `zig build test`
Expected: PASS, exit 0. (All earlier `control.zig` tests still pass — non-block lines skip the new `in_block` guard.)

- [ ] **Step 5: Commit**

```bash
git add src/tmux/control.zig
git commit -m "feat(tmux): handle %begin/%end command-reply blocks"
```

---

## Task 7: layout.zig scaffold + leaf cell + checksum strip

A tmux layout cell is `WxH,X,Y` followed by either `,paneid` (a leaf) or `{...}`/`[...]` (a split). The string may carry a 4-hex-digit checksum prefix (`bd1b,...`); `%layout-change` strings sometimes omit it. This task parses a single leaf and strips the optional checksum.

**Files:**
- Create: `src/tmux/layout.zig`
- Modify: `src/test_fast.zig` (register import)

- [ ] **Step 1: Create `src/tmux/layout.zig`**

```zig
//! tmux layout-string parser. Pure: depends only on `std`.
//!
//! Grammar (tmux `window_layout`):
//!   layout := [checksum ','] cell
//!   cell   := W 'x' H ',' X ',' Y ( ',' paneid | '{' cells '}' | '[' cells ']' )
//!   cells  := cell (',' cell)*
//! `{...}` lays panes left-to-right (horizontal row); `[...]` top-to-bottom.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Dir = enum { horizontal, vertical };

pub const Node = union(enum) {
    leaf: Leaf,
    split: Split,

    pub const Leaf = struct { x: u32, y: u32, w: u32, h: u32, pane_id: usize };
    pub const Split = struct { dir: Dir, x: u32, y: u32, w: u32, h: u32, children: []Node };
};

/// Owns an arena holding the whole node tree. Call `deinit` to free it all.
pub const Layout = struct {
    arena: std.heap.ArenaAllocator,
    root: Node,

    pub fn deinit(self: *Layout) void {
        self.arena.deinit();
    }
};

pub const ParseError = error{SyntaxError} || Allocator.Error;

pub fn parse(gpa: Allocator, str: []const u8) ParseError!Layout {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    var p = CellParser{ .s = stripChecksum(str), .i = 0, .arena = arena.allocator() };
    const root = try p.parseCell();
    if (p.i != p.s.len) return error.SyntaxError;
    return .{ .arena = arena, .root = root };
}

fn stripChecksum(str: []const u8) []const u8 {
    // A checksum prefix is exactly 4 hex digits then ','. A cell instead has
    // 'x' within its first token (e.g. "80x24"), and widths are decimal-only,
    // so this never misfires on a leading cell.
    if (str.len >= 5 and str[4] == ',' and
        isHex(str[0]) and isHex(str[1]) and isHex(str[2]) and isHex(str[3]))
        return str[5..];
    return str;
}

const CellParser = struct {
    s: []const u8,
    i: usize,
    arena: Allocator,

    fn peek(self: *CellParser) ?u8 {
        return if (self.i < self.s.len) self.s[self.i] else null;
    }

    fn expect(self: *CellParser, c: u8) ParseError!void {
        if (self.peek() != c) return error.SyntaxError;
        self.i += 1;
    }

    fn parseU32(self: *CellParser) ParseError!u32 {
        const start = self.i;
        while (self.i < self.s.len and self.s[self.i] >= '0' and self.s[self.i] <= '9') self.i += 1;
        if (self.i == start) return error.SyntaxError;
        return std.fmt.parseInt(u32, self.s[start..self.i], 10) catch return error.SyntaxError;
    }

    fn parseCell(self: *CellParser) ParseError!Node {
        const w = try self.parseU32();
        try self.expect('x');
        const h = try self.parseU32();
        try self.expect(',');
        const x = try self.parseU32();
        try self.expect(',');
        const y = try self.parseU32();
        switch (self.peek() orelse return error.SyntaxError) {
            ',' => {
                self.i += 1;
                const pane_id = try self.parseU32();
                return .{ .leaf = .{ .x = x, .y = y, .w = w, .h = h, .pane_id = pane_id } };
            },
            else => return error.SyntaxError,
        }
    }
};

fn isHex(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

test "parses a single leaf cell with checksum prefix" {
    var layout = try parse(std.testing.allocator, "bd1b,80x24,0,0,1");
    defer layout.deinit();
    const leaf = layout.root.leaf;
    try std.testing.expectEqual(@as(u32, 80), leaf.w);
    try std.testing.expectEqual(@as(u32, 24), leaf.h);
    try std.testing.expectEqual(@as(u32, 0), leaf.x);
    try std.testing.expectEqual(@as(u32, 0), leaf.y);
    try std.testing.expectEqual(@as(usize, 1), leaf.pane_id);
}

test "parses a leaf cell without a checksum prefix" {
    var layout = try parse(std.testing.allocator, "80x24,0,0,5");
    defer layout.deinit();
    try std.testing.expectEqual(@as(usize, 5), layout.root.leaf.pane_id);
}

test "rejects trailing garbage" {
    try std.testing.expectError(error.SyntaxError, parse(std.testing.allocator, "80x24,0,0,1xx"));
}
```

Then register it in `src/test_fast.zig` (inside the `test { ... }` block):

```zig
    _ = @import("tmux/layout.zig");
```

- [ ] **Step 2: Run to verify it passes**

Run: `zig build test`
Expected: PASS, exit 0.

- [ ] **Step 3: Commit**

```bash
git add src/tmux/layout.zig src/test_fast.zig
git commit -m "feat(tmux): layout parser scaffold + leaf cell + checksum strip"
```

---

## Task 8: horizontal split `{...}`

**Files:**
- Modify: `src/tmux/layout.zig`

- [ ] **Step 1: Add the failing test**

```zig
test "parses a horizontal split of two leaves" {
    var layout = try parse(std.testing.allocator, "bd1b,80x24,0,0{40x24,0,0,1,39x24,41,0,2}");
    defer layout.deinit();
    const split = layout.root.split;
    try std.testing.expectEqual(Dir.horizontal, split.dir);
    try std.testing.expectEqual(@as(usize, 2), split.children.len);
    try std.testing.expectEqual(@as(usize, 1), split.children[0].leaf.pane_id);
    try std.testing.expectEqual(@as(u32, 41), split.children[1].leaf.x);
    try std.testing.expectEqual(@as(usize, 2), split.children[1].leaf.pane_id);
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test`
Expected: FAIL — `parseCell` hits `{` and returns `error.SyntaxError`.

- [ ] **Step 3: Implement split parsing**

In `parseCell`, replace the `switch (self.peek() orelse return error.SyntaxError) { ... }` with:

```zig
        switch (self.peek() orelse return error.SyntaxError) {
            ',' => {
                self.i += 1;
                const pane_id = try self.parseU32();
                return .{ .leaf = .{ .x = x, .y = y, .w = w, .h = h, .pane_id = pane_id } };
            },
            '{' => return self.parseChildren('{', '}', .horizontal, x, y, w, h),
            else => return error.SyntaxError,
        }
```

Add the `parseChildren` method to `CellParser`:

```zig
    fn parseChildren(
        self: *CellParser,
        open: u8,
        close: u8,
        dir: Dir,
        x: u32,
        y: u32,
        w: u32,
        h: u32,
    ) ParseError!Node {
        try self.expect(open);
        var children: std.ArrayListUnmanaged(Node) = .empty;
        while (true) {
            const child = try self.parseCell();
            try children.append(self.arena, child);
            const c = self.peek() orelse return error.SyntaxError;
            if (c == ',') {
                self.i += 1;
                continue;
            }
            if (c == close) {
                self.i += 1;
                break;
            }
            return error.SyntaxError;
        }
        return .{ .split = .{ .dir = dir, .x = x, .y = y, .w = w, .h = h, .children = children.items } };
    }
```

- [ ] **Step 4: Run to verify it passes**

Run: `zig build test`
Expected: PASS, exit 0.

- [ ] **Step 5: Commit**

```bash
git add src/tmux/layout.zig
git commit -m "feat(tmux): parse horizontal pane splits"
```

---

## Task 9: vertical split `[...]` + nesting

**Files:**
- Modify: `src/tmux/layout.zig`

- [ ] **Step 1: Add the failing tests**

```zig
test "parses a vertical split" {
    var layout = try parse(std.testing.allocator, "80x24,0,0[80x12,0,0,1,80x11,0,13,2]");
    defer layout.deinit();
    const split = layout.root.split;
    try std.testing.expectEqual(Dir.vertical, split.dir);
    try std.testing.expectEqual(@as(usize, 2), split.children.len);
    try std.testing.expectEqual(@as(u32, 13), split.children[1].leaf.y);
}

test "parses a split nested inside a split" {
    var layout = try parse(std.testing.allocator, "80x24,0,0{40x24,0,0,1,39x24,41,0[39x12,41,0,2,39x11,41,13,3]}");
    defer layout.deinit();
    const outer = layout.root.split;
    try std.testing.expectEqual(Dir.horizontal, outer.dir);
    const inner = outer.children[1].split;
    try std.testing.expectEqual(Dir.vertical, inner.dir);
    try std.testing.expectEqual(@as(usize, 2), inner.children.len);
    try std.testing.expectEqual(@as(usize, 3), inner.children[1].leaf.pane_id);
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `zig build test`
Expected: FAIL — `parseCell` hits `[` and returns `error.SyntaxError`.

- [ ] **Step 3: Add the `[` branch**

In `parseCell`'s `switch`, add the `'['` case (before `else`):

```zig
            '[' => return self.parseChildren('[', ']', .vertical, x, y, w, h),
```

- [ ] **Step 4: Run to verify they pass**

Run: `zig build test`
Expected: PASS, exit 0.

- [ ] **Step 5: Commit**

```bash
git add src/tmux/layout.zig
git commit -m "feat(tmux): parse vertical and nested pane splits"
```

---

## Task 10: layout checksum

tmux prefixes `window_layout` with a 16-bit checksum (`%04x`). Implement and unit-test the algorithm so a later phase can verify layouts. Parsing does not depend on it.

**Files:**
- Modify: `src/tmux/layout.zig`

- [ ] **Step 1: Add the failing tests**

The expected values below are computed directly from tmux's algorithm (`csum = (csum >> 1) + ((csum & 1) << 15); csum += c;` per byte, 16-bit wrapping): `""` → 0; `"a"` (0x61) → 97; `"ab"` → 32914.

```zig
test "checksum matches tmux's rotate-add algorithm" {
    try std.testing.expectEqual(@as(u16, 0), checksum(""));
    try std.testing.expectEqual(@as(u16, 97), checksum("a"));
    try std.testing.expectEqual(@as(u16, 32914), checksum("ab"));
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test`
Expected: FAIL — `checksum` is undefined (compile error).

- [ ] **Step 3: Implement `checksum`**

```zig
/// tmux layout checksum (16-bit, computed over the cell portion of the layout
/// string, i.e. without the `csum,` prefix). tmux formats it as `%04x`.
pub fn checksum(layout: []const u8) u16 {
    var csum: u16 = 0;
    for (layout) |c| {
        csum = (csum >> 1) +% ((csum & 1) << 15);
        csum +%= c;
    }
    return csum;
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `zig build test`
Expected: PASS, exit 0.

- [ ] **Step 5: Commit**

```bash
git add src/tmux/layout.zig
git commit -m "feat(tmux): layout checksum helper"
```

---

## Task 11: cross-module wiring test

Prove the two modules compose: a `%layout-change` notification's layout string parses into a tree. This is the seam the controller will use in Phase 2.

**Files:**
- Create: `src/tmux/protocol_test.zig`
- Modify: `src/test_fast.zig` (register import)

- [ ] **Step 1: Create `src/tmux/protocol_test.zig`**

```zig
//! Wiring tests across the two pure tmux modules. Kept separate so neither
//! `control.zig` nor `layout.zig` imports the other.

const std = @import("std");
const control = @import("control.zig");
const layout = @import("layout.zig");

fn feed(p: *control.Parser, s: []const u8) !?control.Notification {
    var result: ?control.Notification = null;
    for (s) |b| {
        if (try p.put(b)) |n| result = n;
    }
    return result;
}

test "a %layout-change layout string parses into a pane tree" {
    var p = control.Parser.init(std.testing.allocator);
    defer p.deinit();

    const n = (try feed(&p, "%layout-change @1 bd1b,80x24,0,0{40x24,0,0,1,39x24,41,0,2} bd1b,80x24,0,0{40x24,0,0,1,39x24,41,0,2} *\n")).?;
    try std.testing.expectEqual(@as(usize, 1), n.layout_change.window_id);

    var tree = try layout.parse(std.testing.allocator, n.layout_change.layout);
    defer tree.deinit();

    const split = tree.root.split;
    try std.testing.expectEqual(layout.Dir.horizontal, split.dir);
    try std.testing.expectEqual(@as(usize, 2), split.children.len);
    try std.testing.expectEqual(@as(usize, 1), split.children[0].leaf.pane_id);
    try std.testing.expectEqual(@as(usize, 2), split.children[1].leaf.pane_id);
}
```

Then register it in `src/test_fast.zig` (inside the `test { ... }` block):

```zig
    _ = @import("tmux/protocol_test.zig");
```

- [ ] **Step 2: Run to verify it passes**

Run: `zig build test`
Expected: PASS, exit 0.

- [ ] **Step 3: Run the full suite as a regression gate**

Run: `zig build test-full`
Expected: PASS, exit 0 (no regressions in the broader graph).

- [ ] **Step 4: Commit**

```bash
git add src/tmux/protocol_test.zig src/test_fast.zig
git commit -m "test(tmux): wire control-mode notifications into the layout parser"
```

---

## Phase 1 Done — What Ships

A tested, UI-free decoder library: `control.Parser` (all notifications we consume + `unescape`) and `layout.parse` (full nested layout trees + `checksum`), proven to compose. No behavior change for users; nothing is wired to a connection yet.

## Roadmap (subsequent phases — separate plans)

- **Phase 2 — Virtual PTY + headless controller.** Add the virtual `Pty` backend (POSIX `socketpair`); build `src/tmux/session.zig` driven by a *fake control server* (scripted bytes) that demuxes `%output` to panes, reconciles layouts, sequences bootstrap commands, and emits `send-keys`/`split-window` — all asserted on model state, no GUI.
- **Phase 3 — UI integration.** Wire the controller to tabs, `split_tree`, and `Surface`s; windows↔tabs, panes↔splits, active-pane focus, `capture-pane` history seeding, `refresh-client -C` resize.
- **Phase 4 — Resilience + UX.** Detach/reconnect overlay with backoff and re-bootstrap; `session_persist` re-attach; per-profile toggle + session-name field; DCS 1000p auto-detect hook; GUI verify on a real server.

---

## Self-Review

**1. Spec coverage (Phase 1 slice):** The spec's Architecture rows `src/tmux/control.zig` (parser, `Notification`, octal unescape) and `src/tmux/layout.zig` (layout→tree, checksum) are fully covered by Tasks 1–11. Test-registration convention (spec Testing + `phantty-test-inclusion-wiring` memory) covered by the `test_fast.zig` edits in Tasks 1, 7, 11. The fake-control-server integration, virtual PTY, UI wiring, reconnect, and profile toggle are explicitly deferred to Phases 2–4 (Roadmap), matching the spec's staged implementation order — no Phase-1 gap.

**2. Placeholder scan:** No `TBD`/`TODO`/"handle errors"/"similar to" placeholders. Every code step contains complete, compilable code and exact commands. The checksum test values are pre-computed from the documented algorithm rather than left as an exercise.

**3. Type consistency:** `Notification` field names (`window_id`, `pane_id`, `session_id`, `name`, `layout`, `data`) are defined once in Task 1 and used unchanged in Tasks 2–11 and `protocol_test.zig`. `Node`/`Node.Leaf`/`Node.Split`/`Dir` defined in Task 7, extended (not renamed) in Tasks 8–9, referenced as `layout.Dir`/`.leaf`/`.split`/`.children` in Task 11. `parse`/`checksum`/`unescape`/`Parser.init`/`put`/`deinit` signatures are stable across all references. `processLine` is intentionally converted from a free function (Task 1) to a method (Task 6) — the only signature change, and Task 6 updates its sole call site in `put`.

One subtlety worth flagging for the executor: in Task 6, `processLine` becomes a method returning `Allocator.Error!?Notification`; the free-function notification parsers (`parseOutput`, etc.) stay non-method and return `?Notification`, which coerces into the error union on `return`. This is deliberate and compiles.
