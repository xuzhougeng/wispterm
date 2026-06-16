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
    block: std.ArrayListUnmanaged(u8) = .empty,
    block_done: bool = false,
    in_block: bool = false,

    pub fn init(alloc: Allocator) Parser {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Parser) void {
        self.line.deinit(self.alloc);
        self.block.deinit(self.alloc);
    }

    /// Feed one byte. Returns a Notification when a control line completes.
    pub fn put(self: *Parser, byte: u8) Allocator.Error!?Notification {
        if (self.line_done) {
            self.line.clearRetainingCapacity();
            self.line_done = false;
        }
        if (self.block_done) {
            self.block.clearRetainingCapacity();
            self.block_done = false;
        }
        if (byte != '\n') {
            try self.line.append(self.alloc, byte);
            return null;
        }
        var line = self.line.items;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        self.line_done = true;
        return self.processLine(line);
    }

    fn processLine(self: *Parser, raw_line: []const u8) Allocator.Error!?Notification {
        // tmux glues the control-mode enter DCS (ESC P 1000 p) onto the first
        // reply line — e.g. `\x1bP1000p%begin …`. Strip it so the following
        // %begin/%error is still recognized; otherwise a failed reconnect
        // `attach` (whose %error names a gone session) would be silently dropped.
        const line = if (std.mem.startsWith(u8, raw_line, "\x1bP1000p"))
            raw_line["\x1bP1000p".len..]
        else
            raw_line;
        if (self.in_block) {
            if (parseBlockTerminator(line)) |terminator| {
                self.in_block = false;
                self.block_done = true;
                return switch (terminator) {
                    .end => .{ .block_end = self.block.items },
                    .err => .{ .block_err = self.block.items },
                };
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
};

const BlockTerminator = enum { end, err };

/// Block payload is raw command output, so a line that merely starts with
/// `%end` or `%error` may still be pane content. tmux terminators have the
/// exact guard-line shape `%end <time> <command_id> <flags>` or `%error ...`.
fn parseBlockTerminator(line_raw: []const u8) ?BlockTerminator {
    var line = line_raw;
    if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];

    var fields = std.mem.tokenizeScalar(u8, line, ' ');
    const cmd = fields.next() orelse return null;
    const terminator: BlockTerminator = if (std.mem.eql(u8, cmd, "%end"))
        .end
    else if (std.mem.eql(u8, cmd, "%error"))
        .err
    else
        return null;

    const time = fields.next() orelse return null;
    const command_id = fields.next() orelse return null;
    const flags = fields.next() orelse return null;
    if (fields.next() != null) return null;

    _ = std.fmt.parseInt(usize, time, 10) catch return null;
    _ = std.fmt.parseInt(usize, command_id, 10) catch return null;
    _ = std.fmt.parseInt(usize, flags, 10) catch return null;
    return terminator;
}

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

fn parseWindowAdd(line: []const u8) ?Notification {
    const prefix = "%window-add ";
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    const tok = std.mem.trimRight(u8, line[prefix.len..], " ");
    if (tok.len < 2 or tok[0] != '@') return null;
    const id = std.fmt.parseInt(usize, tok[1..], 10) catch return null;
    return .{ .window_add = .{ .window_id = id } };
}

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

fn parseSessionChanged(line: []const u8) ?Notification {
    const prefix = "%session-changed ";
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    var it = std.mem.splitScalar(u8, line[prefix.len..], ' ');
    const id_tok = it.next() orelse return null;
    if (id_tok.len < 2 or id_tok[0] != '$') return null;
    const id = std.fmt.parseInt(usize, id_tok[1..], 10) catch return null;
    return .{ .session_changed = .{ .session_id = id, .name = it.rest() } };
}

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
    try std.testing.expectEqualStrings("hello", n.output.data);
}

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

test "block payload may contain lines starting with %end or %error" {
    var p = Parser.init(std.testing.allocator);
    defer p.deinit();
    try std.testing.expectEqual(@as(?Notification, null), try feed(&p, "%begin 1 1 1\n"));
    try std.testing.expectEqual(@as(?Notification, null), try feed(&p, "%end not really\n"));
    try std.testing.expectEqual(@as(?Notification, null), try feed(&p, "%error also not really\n"));
    const n = (try feed(&p, "hello\n%end 1 1 1\n")).?;
    try std.testing.expectEqualStrings("%end not really\n%error also not really\nhello", n.block_end);
}

test "block terminator rejects extra fields and nonnumeric metadata" {
    var p = Parser.init(std.testing.allocator);
    defer p.deinit();
    try std.testing.expectEqual(@as(?Notification, null), try feed(&p, "%begin 1 1 1\n"));
    try std.testing.expectEqual(@as(?Notification, null), try feed(&p, "%end 1 1 1 trailing\n"));
    try std.testing.expectEqual(@as(?Notification, null), try feed(&p, "%error x y z\n"));
    const n = (try feed(&p, "%end 1 1 1\n")).?;
    try std.testing.expectEqualStrings("%end 1 1 1 trailing\n%error x y z", n.block_end);
}

test "strips the control-mode enter DCS glued onto the first %begin (failed attach)" {
    // A reconnect `attach` to a gone session: tmux glues its enter DCS onto the
    // first reply, so `%begin` is not at column 0. The body must still surface as
    // block_err (else the controller never learns the session is gone).
    var p = Parser.init(std.testing.allocator);
    defer p.deinit();
    try std.testing.expectEqual(@as(?Notification, null), try feed(&p, "\x1bP1000p%begin 1 1 0\n"));
    const n = (try feed(&p, "can't find session: wispterm-ngs00\n%error 1 1 0\n")).?;
    try std.testing.expectEqualStrings("can't find session: wispterm-ngs00", n.block_err);
}
