const std = @import("std");
const ghostty_vt = @import("ghostty-vt");
const jupyter_detect = @import("jupyter/detect.zig");

pub const default_max_history_rows: usize = 10_000;

/// Smaller history budget for the live agent/Copilot snapshot path. The full
/// active screen is always included; only this many recent scrollback rows are
/// prepended, so the live interactive screen at the bottom is never crowded out
/// or truncated away. WeChat's remote path keeps the larger default.
pub const agent_max_history_rows: usize = 400;

const RowSpace = enum {
    active,
    screen,
};

/// Web-console variant of `allocTerminalSnapshot`: wraps the plain-text dump
/// with the escape sequences that mirror the host VT's input-affecting mode
/// state (alternate screen, mouse tracking, bracketed paste, ...). Without
/// them a remote xterm never learns that a full-screen TUI (issue #502:
/// Claude Code) enabled mouse tracking before the client connected, so its
/// wheel scrolls an empty local scrollback instead of reaching the app the
/// way the desktop does. Plain-text consumers (agent tools, ctl, Jupyter
/// detection) must keep using `allocTerminalSnapshot`.
pub fn allocTerminalSnapshotWithModes(
    allocator: std.mem.Allocator,
    terminal: *const ghostty_vt.Terminal,
    max_history_rows: usize,
) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    // Must precede the content so it lands in the same screen as on the host.
    if (terminal.screens.active_key == .alternate)
        try out.appendSlice(allocator, "\x1b[?1049h");

    const text = try allocTerminalSnapshot(allocator, terminal, max_history_rows);
    defer allocator.free(text);
    try out.appendSlice(allocator, text);

    try appendInputModes(allocator, &out, terminal);
    return out.toOwnedSlice(allocator);
}

/// Emit only deviations from xterm defaults so a mode-less shell snapshot
/// stays escape-free.
fn appendInputModes(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    terminal: *const ghostty_vt.Terminal,
) !void {
    const modes = &terminal.modes;
    if (modes.get(.cursor_keys)) try out.appendSlice(allocator, "\x1b[?1h");
    if (!modes.get(.cursor_visible)) try out.appendSlice(allocator, "\x1b[?25l");
    if (modes.get(.focus_event)) try out.appendSlice(allocator, "\x1b[?1004h");
    if (modes.get(.bracketed_paste)) try out.appendSlice(allocator, "\x1b[?2004h");
    // No ?1007 (alternate scroll): xterm.js doesn't implement it — on the alt
    // buffer it always converts wheel to arrow keys, which is what we want.
    switch (terminal.flags.mouse_event) {
        .none => return,
        .x10 => try out.appendSlice(allocator, "\x1b[?9h"),
        .normal => try out.appendSlice(allocator, "\x1b[?1000h"),
        .button => try out.appendSlice(allocator, "\x1b[?1002h"),
        .any => try out.appendSlice(allocator, "\x1b[?1003h"),
    }
    switch (terminal.flags.mouse_format) {
        .x10 => {},
        .utf8 => try out.appendSlice(allocator, "\x1b[?1005h"),
        .sgr => try out.appendSlice(allocator, "\x1b[?1006h"),
        .urxvt => try out.appendSlice(allocator, "\x1b[?1015h"),
        .sgr_pixels => try out.appendSlice(allocator, "\x1b[?1016h"),
    }
}

pub fn allocTerminalSnapshot(
    allocator: std.mem.Allocator,
    terminal: *const ghostty_vt.Terminal,
    max_history_rows: usize,
) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    const screen = terminal.screens.active;
    const rows: usize = @intCast(screen.pages.rows);
    const cols: usize = @intCast(screen.pages.cols);
    const total_rows = @max(rows, screen.pages.total_rows);
    const history_total = total_rows - rows;
    const history_rows = @min(history_total, max_history_rows);
    const history_start = history_total - history_rows;

    var wrote_row = false;
    // True once the previously-emitted row was soft-wrapped into the next one;
    // suppresses the \r\n separator so wrapped logical lines stay contiguous.
    var prev_wrapped = false;
    for (history_start..history_total) |row| {
        try appendSnapshotRow(allocator, &out, screen, .screen, row, cols, &wrote_row, &prev_wrapped);
    }
    for (0..rows) |row| {
        try appendSnapshotRow(allocator, &out, screen, .active, row, cols, &wrote_row, &prev_wrapped);
    }

    return out.toOwnedSlice(allocator);
}

fn appendSnapshotRow(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    screen: *const ghostty_vt.Screen,
    row_space: RowSpace,
    row: usize,
    cols: usize,
    wrote_row: *bool,
    prev_wrapped: *bool,
) !void {
    // A soft-wrapped row continues the previous logical line, so don't separate
    // them with \r\n — otherwise long URLs split across rows become undetectable.
    if (wrote_row.* and !prev_wrapped.*) try out.appendSlice(allocator, "\r\n");
    wrote_row.* = true;

    // The row's soft-wrap flag lives on its Row metadata; read it from any cell.
    const row_wrapped = if (screen.pages.getCell(snapshotPoint(row_space, 0, row))) |c| c.row.wrap else false;
    prev_wrapped.* = row_wrapped;

    var last_col: ?usize = null;
    for (0..cols) |col| {
        const cell_data = screen.pages.getCell(snapshotPoint(row_space, col, row)) orelse continue;
        const cp = cell_data.cell.codepoint();
        if (cp != 0 and cp != ' ') last_col = col;
    }

    // Soft-wrapped rows are full by construction; emit the whole width so the
    // continuation joins seamlessly. Non-wrapped rows trim trailing blanks.
    const end_col = if (row_wrapped) cols else (last_col orelse return) + 1;
    for (0..end_col) |col| {
        const cell_data = screen.pages.getCell(snapshotPoint(row_space, col, row)) orelse {
            try out.append(allocator, ' ');
            continue;
        };
        try appendCellText(allocator, out, cell_data);
    }
}

fn snapshotPoint(row_space: RowSpace, col: usize, row: usize) ghostty_vt.Point {
    const coord: ghostty_vt.Coordinate = .{
        .x = @intCast(col),
        .y = @intCast(row),
    };
    return switch (row_space) {
        .active => .{ .active = coord },
        .screen => .{ .screen = coord },
    };
}

fn appendCellText(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    cell_data: ghostty_vt.PageList.Cell,
) !void {
    const wide_val: u2 = @intFromEnum(cell_data.cell.wide);
    if (wide_val == 2 or wide_val == 3) return;

    const cp = cell_data.cell.codepoint();
    if (cp == 0 or cp == ' ') {
        try out.append(allocator, ' ');
        return;
    }

    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(@intCast(cp), &buf) catch {
        try out.append(allocator, ' ');
        return;
    };
    try out.appendSlice(allocator, buf[0..len]);

    if (!cell_data.cell.hasGrapheme()) return;
    const page = &cell_data.node.data;
    if (page.lookupGrapheme(cell_data.cell)) |extra_cps| {
        for (extra_cps) |ecp| {
            const extra_len = std.unicode.utf8Encode(@intCast(ecp), &buf) catch continue;
            try out.appendSlice(allocator, buf[0..extra_len]);
        }
    }
}

test "remote terminal snapshot includes scrollback before active screen" {
    var terminal = try ghostty_vt.Terminal.init(std.testing.allocator, .{
        .cols = 16,
        .rows = 3,
        .max_scrollback = 1024,
    });
    defer terminal.deinit(std.testing.allocator);

    var stream = terminal.vtStream();
    defer stream.deinit();
    stream.nextSlice("line1\r\nline2\r\nline3\r\nline4\r\nline5\r\nline6");

    const snapshot = try allocTerminalSnapshot(std.testing.allocator, &terminal, 1024);
    defer std.testing.allocator.free(snapshot);

    try std.testing.expect(std.mem.indexOf(u8, snapshot, "line1") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "line6") != null);
    try std.testing.expectEqual(terminal.screens.active.pages.total_rows, snapshotRowCount(snapshot));
}

fn snapshotRowCount(snapshot: []const u8) usize {
    if (snapshot.len == 0) return 0;
    return std.mem.count(u8, snapshot, "\r\n") + 1;
}

test "agent snapshot caps history to the most recent rows but keeps the active screen" {
    var terminal = try ghostty_vt.Terminal.init(std.testing.allocator, .{
        .cols = 16,
        .rows = 3,
        .max_scrollback = 4096,
    });
    defer terminal.deinit(std.testing.allocator);

    var stream = terminal.vtStream();
    defer stream.deinit();
    var i: usize = 1;
    while (i <= 13) : (i += 1) {
        var buf: [32]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "row{d}\r\n", .{i}) catch unreachable;
        stream.nextSlice(line);
    }

    // Cap history to 2 rows: oldest scrollback dropped, active screen kept.
    const snapshot = try allocTerminalSnapshot(std.testing.allocator, &terminal, 2);
    defer std.testing.allocator.free(snapshot);

    try std.testing.expect(std.mem.indexOf(u8, snapshot, "row1\r\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "row13") != null);
}

test "web snapshot mirrors alt-screen and mouse-tracking modes (issue #502)" {
    var terminal = try ghostty_vt.Terminal.init(std.testing.allocator, .{
        .cols = 20,
        .rows = 4,
        .max_scrollback = 1024,
    });
    defer terminal.deinit(std.testing.allocator);

    var stream = terminal.vtStream();
    defer stream.deinit();
    // The modes Claude Code sets at startup, captured from a live PTY.
    stream.nextSlice("\x1b[?1049h\x1b[?1003h\x1b[?1006h\x1b[?1004h\x1b[?2004hTUI FRAME");

    const snapshot = try allocTerminalSnapshotWithModes(std.testing.allocator, &terminal, 1024);
    defer std.testing.allocator.free(snapshot);

    // Alt-screen switch must precede the content so it lands in the alt buffer.
    try std.testing.expect(std.mem.startsWith(u8, snapshot, "\x1b[?1049h"));
    const content_at = std.mem.indexOf(u8, snapshot, "TUI FRAME").?;
    for ([_][]const u8{ "\x1b[?1003h", "\x1b[?1006h", "\x1b[?1004h", "\x1b[?2004h" }) |mode| {
        try std.testing.expect(std.mem.indexOfPos(u8, snapshot, content_at, mode) != null);
    }
}

test "web snapshot of a plain shell stays escape-free and keeps scrollback" {
    var terminal = try ghostty_vt.Terminal.init(std.testing.allocator, .{
        .cols = 16,
        .rows = 3,
        .max_scrollback = 1024,
    });
    defer terminal.deinit(std.testing.allocator);

    var stream = terminal.vtStream();
    defer stream.deinit();
    stream.nextSlice("line1\r\nline2\r\nline3\r\nline4\r\nline5");

    const snapshot = try allocTerminalSnapshotWithModes(std.testing.allocator, &terminal, 1024);
    defer std.testing.allocator.free(snapshot);

    try std.testing.expect(std.mem.indexOfScalar(u8, snapshot, 0x1b) == null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "line1") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "line5") != null);
}

test "soft-wrapped line is joined into one logical line (no \\r\\n mid-wrap)" {
    // Regression: a long Jupyter URL printed into a terminal narrower than the
    // URL soft-wraps across rows. The snapshot must NOT insert \r\n at the wrap
    // boundary, or `jupyter_detect` (which treats \r/\n as non-URL bytes) splits
    // the URL and fails to match it — the macOS/narrow-window detection bug.
    var terminal = try ghostty_vt.Terminal.init(std.testing.allocator, .{
        .cols = 40,
        .rows = 6,
        .max_scrollback = 1024,
    });
    defer terminal.deinit(std.testing.allocator);

    var stream = terminal.vtStream();
    defer stream.deinit();
    const url = "http://localhost:8888/lab?token=abcdef0123456789abcdef0123456789";
    stream.nextSlice("To access the server, open this URL:\r\n    ");
    stream.nextSlice(url);
    stream.nextSlice("\r\n");

    const snapshot = try allocTerminalSnapshot(std.testing.allocator, &terminal, 1024);
    defer std.testing.allocator.free(snapshot);

    // The full URL must survive intact across the soft-wrap boundary.
    try std.testing.expect(std.mem.indexOf(u8, snapshot, url) != null);

    // End-to-end: the snapshot of a narrow terminal must still let the detector
    // find the wrapped Jupyter URL (the user-visible macOS auto-detect bug).
    const result = try jupyter_detect.findJupyterUrls(std.testing.allocator, snapshot);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), result.urls.len);
    try std.testing.expectEqualStrings(url, result.urls[0]);
}
