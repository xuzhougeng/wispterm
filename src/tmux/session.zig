//! Headless tmux control-mode controller. Consumes the Phase 1 parsers
//! (`control`, `layout`), maintains a window/pane model from pushed
//! notifications, queues outbound tmux commands, and delivers pane output
//! through a `PaneSink`. No Surface / PTY / fd dependency — Phase 3 wires those
//! across the sink and `sendKeys` seams.

const std = @import("std");
const Allocator = std.mem.Allocator;
const control = @import("control.zig");
const layout = @import("layout.zig");

/// Receives unescaped pane output bytes. Phase 3 backs this with a virtual PTY
/// feeding a Surface; tests back it with a per-pane collector. `bytes` is only
/// valid for the duration of the call.
pub const PaneSink = struct {
    ctx: *anyopaque,
    writeFn: *const fn (ctx: *anyopaque, pane_id: usize, bytes: []const u8) void,

    pub fn write(self: PaneSink, pane_id: usize, bytes: []const u8) void {
        self.writeFn(self.ctx, pane_id, bytes);
    }
};

pub const Session = struct {
    alloc: Allocator,
    parser: control.Parser,
    sink: PaneSink,
    cols: u16,
    rows: u16,
    cmds: std.ArrayListUnmanaged(u8) = .empty,
    scratch: std.ArrayListUnmanaged(u8) = .empty,
    windows: std.ArrayListUnmanaged(Window) = .empty,
    /// FIFO of pane ids awaiting a `capture-pane` reply (Phase 3d scrollback
    /// seeding). Replies arrive in command order, so the front matches the next
    /// non-window-list `block_end`.
    capture_queue: std.ArrayListUnmanaged(usize) = .empty,
    active_window: ?usize = null,
    active_pane: ?usize = null,
    exited: bool = false,
    /// Set when a command reply is a `%error` whose body says the attach target
    /// is gone ("can't find session" / "no sessions"). On a reconnect `attach`
    /// this means the user genuinely ended the session, so the controller closes
    /// rather than looping reconnects. Distinct from `exited` (which also fires on
    /// a survivable transport drop). Reset by `resetForReconnect`.
    session_gone: bool = false,
    events: EventSink = .{},

    pub const Window = struct {
        id: usize,
        active: bool = false,
        name: std.ArrayListUnmanaged(u8) = .empty,
        panes: std.ArrayListUnmanaged(usize) = .empty,

        fn deinit(self: *Window, alloc: Allocator) void {
            self.name.deinit(alloc);
            self.panes.deinit(alloc);
        }
    };

    /// High-level model events for the UI bridge (Phase 3c-2). The mirror of
    /// `PaneSink`: the controller is Surface-agnostic, so it pushes typed events
    /// to a sink the bridge backs with tab/Surface side effects. All callbacks
    /// are best-effort (`void`) — the bridge handles its own allocation
    /// failures, like `PaneSink.write`. `root`/`name` are only valid for the
    /// duration of the call. The default sink ignores everything (headless/unit
    /// use).
    pub const EventSink = struct {
        ctx: *anyopaque = undefined,
        onLayoutChange: *const fn (ctx: *anyopaque, window_id: usize, root: *const layout.Node) void = noLayout,
        onWindowRenamed: *const fn (ctx: *anyopaque, window_id: usize, name: []const u8) void = noRename,
        onWindowClose: *const fn (ctx: *anyopaque, window_id: usize) void = noClose,
        onActiveWindowChanged: *const fn (ctx: *anyopaque, window_id: usize) void = noActiveWindow,
        onActivePaneChanged: *const fn (ctx: *anyopaque, pane_id: usize) void = noActive,
        onPaneMeta: *const fn (ctx: *anyopaque, pane_id: usize, path: []const u8, cmd: []const u8) void = noPaneMeta,

        fn noLayout(_: *anyopaque, _: usize, _: *const layout.Node) void {}
        fn noRename(_: *anyopaque, _: usize, _: []const u8) void {}
        fn noClose(_: *anyopaque, _: usize) void {}
        fn noActiveWindow(_: *anyopaque, _: usize) void {}
        fn noActive(_: *anyopaque, _: usize) void {}
        fn noPaneMeta(_: *anyopaque, _: usize, _: []const u8, _: []const u8) void {}
    };

    pub fn init(alloc: Allocator, sink: PaneSink, cols: u16, rows: u16) Session {
        return .{
            .alloc = alloc,
            .parser = control.Parser.init(alloc),
            .sink = sink,
            .cols = cols,
            .rows = rows,
        };
    }

    pub fn deinit(self: *Session) void {
        self.parser.deinit();
        self.cmds.deinit(self.alloc);
        self.scratch.deinit(self.alloc);
        self.capture_queue.deinit(self.alloc);
        for (self.windows.items) |*w| w.deinit(self.alloc);
        self.windows.deinit(self.alloc);
    }

    pub fn windowCount(self: *const Session) usize {
        return self.windows.items.len;
    }

    pub fn pendingCommands(self: *const Session) []const u8 {
        return self.cmds.items;
    }

    pub fn clearCommands(self: *Session) void {
        self.cmds.clearRetainingCapacity();
    }

    /// Reset transient stream state for a transport reconnect: the byte parser
    /// (the dropped stream may have left a partial line), the outbound command
    /// queue, and the pending capture-pane FIFO. The window/pane model is kept —
    /// the post-reconnect `list-windows` refreshes it and the bridge reuses the
    /// same surfaces by pane id.
    pub fn resetForReconnect(self: *Session) void {
        self.parser.deinit();
        self.parser = control.Parser.init(self.alloc);
        self.cmds.clearRetainingCapacity();
        self.capture_queue.clearRetainingCapacity();
        self.exited = false;
        self.session_gone = false;
    }

    pub fn feed(self: *Session, bytes: []const u8) Allocator.Error!void {
        for (bytes) |b| {
            if (try self.parser.put(b)) |n| try self.handle(n);
        }
    }

    fn handle(self: *Session, n: control.Notification) Allocator.Error!void {
        switch (n) {
            .output => |o| {
                self.scratch.clearRetainingCapacity();
                try control.unescape(self.alloc, &self.scratch, o.data);
                self.sink.write(o.pane_id, self.scratch.items);
            },
            .layout_change => |lc| try self.applyLayout(lc.window_id, lc.layout),
            // A command-reply block. On attach tmux does NOT emit %layout-change,
            // so the initial windows/layouts are learned from the `list-windows`
            // reply that arrives here as `@<id> <layout>` lines (Phase 3d
            // bootstrap). If it is not a window list, check by content whether it
            // is a `list-panes` reply (`%<id>\t…` shape on every non-empty line);
            // if so emit onPaneMeta — this must take priority over the capture FIFO
            // because `start()` enqueues list-panes before any captures but
            // `capturePane()` may be called during layout reconcile (inside the
            // earlier list-windows reply) so the queue can already be non-empty
            // when the list-panes reply lands. Otherwise route to the next queued
            // `capture-pane` pane sink (FIFO). Anything else is ignored.
            .block_end => |body| {
                if (!try self.applyWindowList(body)) {
                    if (isPaneListReply(body)) {
                        _ = self.applyPaneList(body); // emits onPaneMeta per line
                    } else if (self.capture_queue.items.len > 0) {
                        const pane_id = self.capture_queue.orderedRemove(0);
                        // Repaint from the top-left, translating LF→CRLF: the
                        // capture's rows are joined by '\n' only, and the
                        // terminal's line feed moves down without returning to
                        // column 0 — without the '\r' each row staircases right.
                        self.scratch.clearRetainingCapacity();
                        try self.scratch.appendSlice(self.alloc, "\x1b[2J\x1b[H");
                        for (body) |c| {
                            if (c == '\n') {
                                try self.scratch.appendSlice(self.alloc, "\r\n");
                            } else {
                                try self.scratch.append(self.alloc, c);
                            }
                        }
                        self.sink.write(pane_id, self.scratch.items);
                    }
                }
            },
            .block_err => |body| {
                // A reconnect `attach` to a session the user ended replies with a
                // `%error` whose body names the failure; flag it so the controller
                // tears down instead of recreating the session.
                if (isSessionGoneError(body)) self.session_gone = true;
                // Keep the capture FIFO aligned if a capture errored.
                if (self.capture_queue.items.len > 0) _ = self.capture_queue.orderedRemove(0);
            },
            .window_add => |w| _ = try self.ensureWindow(w.window_id),
            .window_renamed => |w| {
                try self.renameWindow(w.window_id, w.name);
                self.events.onWindowRenamed(self.events.ctx, w.window_id, w.name);
            },
            .window_close => |w| {
                self.events.onWindowClose(self.events.ctx, w.window_id);
                self.removeWindow(w.window_id);
            },
            .window_pane_changed => |w| {
                self.active_window = w.window_id;
                self.active_pane = w.pane_id;
                self.events.onActivePaneChanged(self.events.ctx, w.pane_id);
            },
            .exit => self.exited = true,
            else => {},
        }
    }

    pub fn findWindow(self: *Session, id: usize) ?*Window {
        for (self.windows.items) |*w| {
            if (w.id == id) return w;
        }
        return null;
    }

    fn ensureWindow(self: *Session, id: usize) Allocator.Error!*Window {
        if (self.findWindow(id)) |w| return w;
        try self.windows.append(self.alloc, .{ .id = id });
        return &self.windows.items[self.windows.items.len - 1];
    }

    fn renameWindow(self: *Session, id: usize, name: []const u8) Allocator.Error!void {
        const w = try self.ensureWindow(id);
        w.name.clearRetainingCapacity();
        try w.name.appendSlice(self.alloc, name);
    }

    fn removeWindow(self: *Session, id: usize) void {
        var i: usize = 0;
        while (i < self.windows.items.len) : (i += 1) {
            if (self.windows.items[i].id == id) {
                self.windows.items[i].deinit(self.alloc);
                _ = self.windows.orderedRemove(i);
                if (self.active_window == id) self.active_window = null;
                return;
            }
        }
    }

    fn applyLayout(self: *Session, window_id: usize, layout_str: []const u8) Allocator.Error!void {
        var tree = layout.parse(self.alloc, layout_str) catch return; // ignore malformed layouts
        defer tree.deinit();
        const w = try self.ensureWindow(window_id);
        w.panes.clearRetainingCapacity();
        try collectPanes(self.alloc, &w.panes, tree.root);
        // `tree` is still alive (its `deinit` runs at scope exit); the bridge
        // consumes `root` synchronously inside this call.
        self.events.onLayoutChange(self.events.ctx, window_id, &tree.root);
    }

    /// Parse a `list-windows` reply body and apply each line as a layout. New
    /// replies are tab-separated:
    ///
    ///     #{window_id}\t#{window_active}\t#{window_layout}\t#{window_name}
    ///
    /// Returns true if at least one line applied — the `block_end` handler uses
    /// that to tell a window-list reply apart from a capture-pane reply.
    /// Non-matching lines are skipped.
    fn applyWindowList(self: *Session, body: []const u8) Allocator.Error!bool {
        var applied = false;
        var active_window: ?usize = null;
        var seen: std.ArrayListUnmanaged(usize) = .empty;
        defer seen.deinit(self.alloc);

        var lines = std.mem.splitScalar(u8, body, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \r\t");
            const parsed = parseWindowListLine(line) orelse continue;
            try seen.append(self.alloc, parsed.id);
            try self.applyLayout(parsed.id, parsed.layout_str);
            const w = self.findWindow(parsed.id) orelse continue;
            w.active = parsed.active;
            if (parsed.name) |name| {
                try self.renameWindow(parsed.id, name);
                self.events.onWindowRenamed(self.events.ctx, parsed.id, name);
            }
            if (parsed.active) active_window = parsed.id;
            applied = true;
        }
        if (applied) self.removeWindowsNotIn(seen.items);
        self.active_window = active_window;
        if (active_window) |id| {
            self.events.onActiveWindowChanged(self.events.ctx, id);
        }
        return applied;
    }

    /// Parse a `list-panes -s -F "#{pane_id}\t#{pane_current_path}\t#{pane_current_command}"`
    /// reply body. Each line: `%<id>\t<path>\t<cmd>`. Emits onPaneMeta per line.
    /// Returns true if at least one line applied. The caller (block_end) gates
    /// this via `isPaneListReply` so it is only reached when the body is
    /// unambiguously a pane-list; per-line parsing is lenient (skips malformed).
    fn applyPaneList(self: *Session, body: []const u8) bool {
        var applied = false;
        var lines = std.mem.splitScalar(u8, body, '\n');
        while (lines.next()) |raw| {
            // Trim spaces and \r but NOT \t — tabs are the field separator.
            const line = std.mem.trim(u8, raw, " \r");
            if (line.len < 2 or line[0] != '%') continue;
            const t1 = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
            const id = std.fmt.parseInt(usize, line[1..t1], 10) catch continue;
            const rest = line[t1 + 1 ..];
            const t2 = std.mem.indexOfScalar(u8, rest, '\t') orelse continue;
            const path = rest[0..t2];
            const cmd = rest[t2 + 1 ..];
            self.events.onPaneMeta(self.events.ctx, id, path, cmd);
            applied = true;
        }
        return applied;
    }

    fn removeWindowsNotIn(self: *Session, ids: []const usize) void {
        var i: usize = 0;
        while (i < self.windows.items.len) {
            const id = self.windows.items[i].id;
            if (containsId(ids, id)) {
                i += 1;
                continue;
            }
            self.events.onWindowClose(self.events.ctx, id);
            self.windows.items[i].deinit(self.alloc);
            _ = self.windows.orderedRemove(i);
            if (self.active_window == id) self.active_window = null;
        }
    }

    /// Enqueue a `capture-pane` for a pane and remember it (FIFO) so the reply
    /// can be routed back to the pane's sink to seed its visible screen on
    /// attach. Plain `-p` (NOT `-J`): each visible row is one line ≤ pane width,
    /// so writing it to a matched-width surface reproduces the screen 1:1
    /// without re-wrapping.
    pub fn capturePane(self: *Session, pane_id: usize) Allocator.Error!void {
        var buf: [48]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "capture-pane -p -t %{d}\n", .{pane_id}) catch unreachable;
        try self.cmds.appendSlice(self.alloc, s);
        try self.capture_queue.append(self.alloc, pane_id);
    }

    /// The `list-panes` format string shared between `start` and `refreshPaneMeta`.
    const list_panes_cmd = "list-panes -s -F \"#{pane_id}\t#{pane_current_path}\t#{pane_current_command}\"\n";

    /// Enqueue the attach bootstrap: tell tmux our client size and ask for the
    /// window list. (Parsing the list-windows reply for complete initial
    /// enumeration is Phase 3; the live model is built from pushed
    /// notifications.)
    pub fn start(self: *Session) Allocator.Error!void {
        try self.enqueueResize();
        try self.cmds.appendSlice(self.alloc, "list-windows -F \"#{window_id}\t#{window_active}\t#{window_layout}\t#{window_name}\"\n");
        try self.cmds.appendSlice(self.alloc, list_panes_cmd);
    }

    /// Re-query per-pane metadata (cwd + current command). Called periodically
    /// by the controller; cwd/command change infrequently so a coarse cadence
    /// is fine.
    pub fn refreshPaneMeta(self: *Session) Allocator.Error!void {
        try self.cmds.appendSlice(self.alloc, list_panes_cmd);
    }

    pub fn resizeClient(self: *Session, cols: u16, rows: u16) Allocator.Error!void {
        self.cols = cols;
        self.rows = rows;
        try self.enqueueResize();
    }

    fn enqueueResize(self: *Session) Allocator.Error!void {
        var buf: [64]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "refresh-client -C {d}x{d}\n", .{ self.cols, self.rows }) catch unreachable;
        try self.cmds.appendSlice(self.alloc, s);
    }

    /// Queue raw key bytes for a pane as a hex `send-keys` command.
    pub fn sendKeys(self: *Session, pane_id: usize, raw: []const u8) Allocator.Error!void {
        var head: [48]u8 = undefined;
        const h = std.fmt.bufPrint(&head, "send-keys -t %{d} -H", .{pane_id}) catch unreachable;
        try self.cmds.appendSlice(self.alloc, h);
        for (raw) |byte| {
            var hb: [8]u8 = undefined;
            const hs = std.fmt.bufPrint(&hb, " {x:0>2}", .{byte}) catch unreachable;
            try self.cmds.appendSlice(self.alloc, hs);
        }
        try self.cmds.append(self.alloc, '\n');
    }

    pub fn splitPane(self: *Session, pane_id: usize, dir: layout.Dir) Allocator.Error!void {
        const flag = switch (dir) {
            .horizontal => "-h",
            .vertical => "-v",
        };
        var buf: [48]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "split-window {s} -t %{d}\n", .{ flag, pane_id }) catch unreachable;
        try self.cmds.appendSlice(self.alloc, s);
    }

    pub fn newWindow(self: *Session) Allocator.Error!void {
        try self.cmds.appendSlice(self.alloc, "new-window\n");
    }

    pub fn killWindow(self: *Session, id: usize) Allocator.Error!void {
        var buf: [48]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "kill-window -t @{d}\n", .{id}) catch unreachable;
        try self.cmds.appendSlice(self.alloc, s);
    }

    pub fn killPane(self: *Session, pane_id: usize) Allocator.Error!void {
        var buf: [48]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "kill-pane -t %{d}\n", .{pane_id}) catch unreachable;
        try self.cmds.appendSlice(self.alloc, s);
    }
};

const WindowListLine = struct {
    id: usize,
    active: bool = false,
    layout_str: []const u8,
    name: ?[]const u8 = null,
};

fn parseWindowListLine(line: []const u8) ?WindowListLine {
    if (line.len < 2 or line[0] != '@') return null;
    return parseTabbedWindowListLine(line);
}

fn parseTabbedWindowListLine(line: []const u8) ?WindowListLine {
    const tab1 = std.mem.indexOfScalar(u8, line, '\t') orelse return null;
    const id = std.fmt.parseInt(usize, line[1..tab1], 10) catch return null;
    const rest1 = line[tab1 + 1 ..];
    const tab2 = std.mem.indexOfScalar(u8, rest1, '\t') orelse return null;
    const active = std.mem.eql(u8, rest1[0..tab2], "1");
    const rest2 = rest1[tab2 + 1 ..];
    const tab3 = std.mem.indexOfScalar(u8, rest2, '\t');
    const layout_str = if (tab3) |idx| rest2[0..idx] else rest2;
    if (layout_str.len == 0) return null;
    return .{
        .id = id,
        .active = active,
        .layout_str = layout_str,
        .name = if (tab3) |idx| rest2[idx + 1 ..] else null,
    };
}

/// Returns true iff `body` is a `list-panes` reply: there is at least one
/// non-empty line AND every non-empty line matches `%<digits>\t…` (starts with
/// `%`, has a numeric id before the first `\t`, and contains at least one `\t`).
/// A single non-matching non-empty line → false. Blank/whitespace-only lines
/// are ignored. This strict check lets block_end distinguish a pane-list reply
/// from real capture scrollback (which won't have ALL lines in that shape).
fn isPaneListReply(body: []const u8) bool {
    var found_any = false;
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len == 0) continue; // ignore blank lines
        // Must start with '%' and have at least one '\t'.
        if (line[0] != '%') return false;
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse return false;
        // The part between '%' and '\t' must be a valid decimal integer (pane id).
        _ = std.fmt.parseInt(usize, line[1..tab], 10) catch return false;
        found_any = true;
    }
    return found_any;
}

/// True if a `%error` reply body says the attach target no longer exists: the
/// session was killed, or the last one exited and the server quit. These are
/// tmux's own English (non-localized) messages. Used to tell a reconnect that
/// found a dead session (close) from one that re-attached a live one (continue).
pub fn isSessionGoneError(body: []const u8) bool {
    return std.mem.indexOf(u8, body, "can't find session") != null or
        std.mem.indexOf(u8, body, "no sessions") != null or
        std.mem.indexOf(u8, body, "no server running") != null or
        std.mem.indexOf(u8, body, "no current session") != null;
}

fn containsId(ids: []const usize, id: usize) bool {
    for (ids) |candidate| {
        if (candidate == id) return true;
    }
    return false;
}

fn collectPanes(
    alloc: Allocator,
    out: *std.ArrayListUnmanaged(usize),
    node: layout.Node,
) Allocator.Error!void {
    switch (node) {
        .leaf => |l| try out.append(alloc, l.pane_id),
        .split => |s| {
            for (s.children) |child| try collectPanes(alloc, out, child);
        },
    }
}

// ----- tests -----

const Collector = struct {
    alloc: Allocator,
    last_pane: usize = 0,
    buf: std.ArrayListUnmanaged(u8) = .empty,

    fn sink(self: *Collector) PaneSink {
        return .{ .ctx = self, .writeFn = writeImpl };
    }

    fn writeImpl(ctx: *anyopaque, pane_id: usize, bytes: []const u8) void {
        const self: *Collector = @ptrCast(@alignCast(ctx));
        self.last_pane = pane_id;
        self.buf.appendSlice(self.alloc, bytes) catch {};
    }

    fn deinit(self: *Collector) void {
        self.buf.deinit(self.alloc);
    }
};

test "session initializes empty" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s.deinit();
    try std.testing.expectEqual(@as(usize, 0), s.windowCount());
    try std.testing.expectEqual(@as(usize, 0), s.pendingCommands().len);
}

test "feed routes unescaped %output to the sink for the right pane" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s.deinit();

    // \033 octal-escapes to ESC (0x1b).
    try s.feed("%output %7 ab\\033c\n");
    try std.testing.expectEqual(@as(usize, 7), col.last_pane);
    try std.testing.expectEqualSlices(u8, &.{ 'a', 'b', 0x1b, 'c' }, col.buf.items);
}

test "window-add/renamed/close maintain the window list" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s.deinit();

    try s.feed("%window-add @3\n");
    try s.feed("%window-add @5\n");
    try std.testing.expectEqual(@as(usize, 2), s.windowCount());

    try s.feed("%window-renamed @3 build\n");
    try std.testing.expectEqualStrings("build", s.findWindow(3).?.name.items);

    try s.feed("%window-close @3\n");
    try std.testing.expectEqual(@as(usize, 1), s.windowCount());
    try std.testing.expect(s.findWindow(3) == null);
}

test "window-pane-changed sets the active pane" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s.deinit();

    try s.feed("%window-pane-changed @1 %9\n");
    try std.testing.expectEqual(@as(?usize, 9), s.active_pane);
}

test "layout-change populates a window's pane list in layout order" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s.deinit();

    try s.feed("%layout-change @1 bd1b,80x24,0,0{40x24,0,0,1,39x24,41,0,2} bd1b,80x24,0,0{40x24,0,0,1,39x24,41,0,2} *\n");
    const panes = s.findWindow(1).?.panes.items;
    try std.testing.expectEqualSlices(usize, &.{ 1, 2 }, panes);
}

test "start enqueues the attach bootstrap commands" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 120, 40);
    defer s.deinit();

    try s.start();
    const cmds = s.pendingCommands();
    try std.testing.expect(std.mem.indexOf(u8, cmds, "refresh-client -C 120x40\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmds, "list-windows") != null);
}

test "resizeClient updates size and queues a refresh" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s.deinit();

    try s.resizeClient(100, 30);
    try std.testing.expectEqual(@as(u16, 100), s.cols);
    try std.testing.expect(std.mem.indexOf(u8, s.pendingCommands(), "refresh-client -C 100x30\n") != null);
}

test "sendKeys hex-encodes raw bytes for a pane" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s.deinit();

    try s.sendKeys(4, "ls\n"); // l=0x6c s=0x73 \n=0x0a
    try std.testing.expectEqualStrings("send-keys -t %4 -H 6c 73 0a\n", s.pendingCommands());
}

test "splitPane emits split-window with the right orientation flag" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s.deinit();

    try s.splitPane(2, .horizontal);
    try std.testing.expectEqualStrings("split-window -h -t %2\n", s.pendingCommands());
    s.clearCommands();
    try s.splitPane(2, .vertical);
    try std.testing.expectEqualStrings("split-window -v -t %2\n", s.pendingCommands());
}

test "newWindow and killWindow emit their commands" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s.deinit();

    try s.newWindow();
    try std.testing.expectEqualStrings("new-window\n", s.pendingCommands());
    s.clearCommands();
    try s.killWindow(6);
    try std.testing.expectEqualStrings("kill-window -t @6\n", s.pendingCommands());
}

test "a realistic notification stream builds the full model" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s.deinit();

    // Attach: one window, a single pane, then it splits into two, output flows,
    // focus moves, and finally tmux exits.
    try s.feed("%window-add @0\n");
    try s.feed("%window-renamed @0 main\n");
    try s.feed("%layout-change @0 bd1b,80x24,0,0,1 bd1b,80x24,0,0,1 *\n");
    try s.feed("%layout-change @0 e2f1,80x24,0,0{40x24,0,0,1,39x24,41,0,2} e2f1,80x24,0,0{40x24,0,0,1,39x24,41,0,2} *\n");
    try s.feed("%window-pane-changed @0 %2\n");
    try s.feed("%output %2 done\n");
    try s.feed("%exit\n");

    try std.testing.expectEqual(@as(usize, 1), s.windowCount());
    const w = s.findWindow(0).?;
    try std.testing.expectEqualStrings("main", w.name.items);
    try std.testing.expectEqualSlices(usize, &.{ 1, 2 }, w.panes.items);
    try std.testing.expectEqual(@as(?usize, 2), s.active_pane);
    try std.testing.expectEqual(@as(usize, 2), col.last_pane);
    try std.testing.expectEqualSlices(u8, "done", col.buf.items);
    try std.testing.expect(s.exited);
}

test "a failed reconnect attach flags session_gone, not just exited" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s.deinit();

    // What `tmux -CC attach -t <gone>` actually replies (control-mode enter DCS
    // glued onto %begin, a %error block naming the failure, then %exit).
    try s.feed("\x1bP1000p%begin 1 1 0\r\ncan't find session: wispterm-ngs00\r\n%error 1 1 0\r\n%exit\r\n");
    try std.testing.expect(s.session_gone);
    try std.testing.expect(s.exited);

    // A bare %exit (survivable transport drop) is NOT a gone session.
    var s2 = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s2.deinit();
    try s2.feed("%exit\n");
    try std.testing.expect(s2.exited);
    try std.testing.expect(!s2.session_gone);

    // The "no sessions" variant (server quit) also counts as gone.
    try std.testing.expect(isSessionGoneError("no sessions"));
    try std.testing.expect(!isSessionGoneError("boom: a normal command error"));
}

const EventLog = struct {
    alloc: Allocator,
    layout_window: ?usize = null,
    layout_panes: usize = 0,
    renamed_window: ?usize = null,
    renamed_name: std.ArrayListUnmanaged(u8) = .empty,
    closed_window: ?usize = null,
    active_window: ?usize = null,
    active_pane: ?usize = null,
    pane_meta_count: usize = 0,
    last_pane_meta_id: ?usize = null,
    last_pane_meta_path: std.ArrayListUnmanaged(u8) = .empty,
    last_pane_meta_cmd: std.ArrayListUnmanaged(u8) = .empty,

    fn eventSink(self: *EventLog) Session.EventSink {
        return .{
            .ctx = self,
            .onLayoutChange = onLayout,
            .onWindowRenamed = onRenamed,
            .onWindowClose = onClose,
            .onActiveWindowChanged = onActiveWindow,
            .onActivePaneChanged = onActive,
            .onPaneMeta = onPaneMeta,
        };
    }

    fn onLayout(ctx: *anyopaque, window_id: usize, root: *const layout.Node) void {
        const self: *EventLog = @ptrCast(@alignCast(ctx));
        self.layout_window = window_id;
        var n: usize = 0;
        countLeaves(root, &n);
        self.layout_panes = n;
    }
    fn onRenamed(ctx: *anyopaque, window_id: usize, name: []const u8) void {
        const self: *EventLog = @ptrCast(@alignCast(ctx));
        self.renamed_window = window_id;
        self.renamed_name.clearRetainingCapacity();
        self.renamed_name.appendSlice(self.alloc, name) catch {};
    }
    fn onClose(ctx: *anyopaque, window_id: usize) void {
        const self: *EventLog = @ptrCast(@alignCast(ctx));
        self.closed_window = window_id;
    }
    fn onActiveWindow(ctx: *anyopaque, window_id: usize) void {
        const self: *EventLog = @ptrCast(@alignCast(ctx));
        self.active_window = window_id;
    }
    fn onActive(ctx: *anyopaque, pane_id: usize) void {
        const self: *EventLog = @ptrCast(@alignCast(ctx));
        self.active_pane = pane_id;
    }
    fn countLeaves(node: *const layout.Node, out: *usize) void {
        switch (node.*) {
            .leaf => out.* += 1,
            .split => |s| for (s.children) |*c| countLeaves(c, out),
        }
    }
    fn onPaneMeta(ctx: *anyopaque, pane_id: usize, path: []const u8, cmd: []const u8) void {
        const self: *EventLog = @ptrCast(@alignCast(ctx));
        self.pane_meta_count += 1;
        self.last_pane_meta_id = pane_id;
        self.last_pane_meta_path.clearRetainingCapacity();
        self.last_pane_meta_path.appendSlice(self.alloc, path) catch {};
        self.last_pane_meta_cmd.clearRetainingCapacity();
        self.last_pane_meta_cmd.appendSlice(self.alloc, cmd) catch {};
    }

    fn deinit(self: *EventLog) void {
        self.renamed_name.deinit(self.alloc);
        self.last_pane_meta_path.deinit(self.alloc);
        self.last_pane_meta_cmd.deinit(self.alloc);
    }
};

test "EventSink fires onLayoutChange with the parsed root" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var log = EventLog{ .alloc = std.testing.allocator };
    defer log.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s.deinit();
    s.events = log.eventSink();

    try s.feed("%layout-change @4 bd1b,80x24,0,0{40x24,0,0,1,39x24,41,0,2} bd1b,80x24,0,0{40x24,0,0,1,39x24,41,0,2} *\n");
    try std.testing.expectEqual(@as(?usize, 4), log.layout_window);
    try std.testing.expectEqual(@as(usize, 2), log.layout_panes);
}

test "EventSink fires onWindowRenamed with the name" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var log = EventLog{ .alloc = std.testing.allocator };
    defer log.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s.deinit();
    s.events = log.eventSink();

    try s.feed("%window-renamed @7 build\n");
    try std.testing.expectEqual(@as(?usize, 7), log.renamed_window);
    try std.testing.expectEqualStrings("build", log.renamed_name.items);
}

test "EventSink fires onWindowClose before the window is dropped" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var log = EventLog{ .alloc = std.testing.allocator };
    defer log.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s.deinit();
    s.events = log.eventSink();

    try s.feed("%window-add @3\n");
    try s.feed("%window-close @3\n");
    try std.testing.expectEqual(@as(?usize, 3), log.closed_window);
    try std.testing.expect(s.findWindow(3) == null);
}

test "EventSink fires onActivePaneChanged" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var log = EventLog{ .alloc = std.testing.allocator };
    defer log.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s.deinit();
    s.events = log.eventSink();

    try s.feed("%window-pane-changed @1 %9\n");
    try std.testing.expectEqual(@as(?usize, 9), log.active_pane);
}

test "block_end list-windows reply drives onLayoutChange per window (bootstrap)" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var log = EventLog{ .alloc = std.testing.allocator };
    defer log.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s.deinit();
    s.events = log.eventSink();

    // The reply tmux sends on attach to `list-windows -F "#{window_id}\t#{window_active}\t#{window_layout}\t#{window_name}"`.
    try s.feed("%begin 1 1 0\n@1\t1\tb25e,80x24,0,0,1\tshell\n%end 1 1 0\n");
    try std.testing.expectEqual(@as(?usize, 1), log.layout_window);
    try std.testing.expectEqual(@as(usize, 1), log.layout_panes);
    try std.testing.expectEqual(@as(usize, 1), s.windowCount());
    try std.testing.expectEqualStrings("shell", s.findWindow(1).?.name.items);

    // A non-window-list reply body must not create windows.
    try s.feed("%begin 2 2 0\nsome other output\n%end 2 2 0\n");
    try std.testing.expectEqual(@as(usize, 1), s.windowCount());
}

test "block_end list-windows reply carries window names and the active window" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var log = EventLog{ .alloc = std.testing.allocator };
    defer log.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s.deinit();
    s.events = log.eventSink();

    try s.feed(
        "%begin 1 1 0\n" ++
            "@1\t0\tb25e,80x24,0,0,1\tbuild\n" ++
            "@2\t1\tb25e,80x24,0,0,2\teditor tab\n" ++
            "%end 1 1 0\n",
    );

    try std.testing.expectEqual(@as(usize, 2), s.windowCount());
    try std.testing.expectEqualStrings("build", s.findWindow(1).?.name.items);
    try std.testing.expectEqualStrings("editor tab", s.findWindow(2).?.name.items);
    try std.testing.expect(!s.findWindow(1).?.active);
    try std.testing.expect(s.findWindow(2).?.active);
    try std.testing.expectEqual(@as(?usize, 2), s.active_window);
    try std.testing.expectEqual(@as(?usize, 2), log.active_window);
    try std.testing.expectEqual(@as(?usize, 2), log.renamed_window);
    try std.testing.expectEqualStrings("editor tab", log.renamed_name.items);
}

test "block_end list-windows reply removes windows absent from the full refresh" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var log = EventLog{ .alloc = std.testing.allocator };
    defer log.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s.deinit();
    s.events = log.eventSink();

    try s.feed(
        "%begin 1 1 0\n" ++
            "@1\t0\tb25e,80x24,0,0,1\told\n" ++
            "@2\t1\tb25e,80x24,0,0,2\tkeep\n" ++
            "%end 1 1 0\n",
    );
    try std.testing.expectEqual(@as(usize, 2), s.windowCount());

    try s.feed("%begin 2 2 0\n@2\t1\tb25e,80x24,0,0,2\tkeep\n%end 2 2 0\n");
    try std.testing.expectEqual(@as(usize, 1), s.windowCount());
    try std.testing.expect(s.findWindow(1) == null);
    try std.testing.expect(s.findWindow(2) != null);
    try std.testing.expectEqual(@as(?usize, 1), log.closed_window);
}

test "capture-pane reply is routed to the pane sink (scrollback seed)" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s.deinit();

    try s.capturePane(5);
    try std.testing.expect(std.mem.indexOf(u8, s.pendingCommands(), "capture-pane -p -t %5\n") != null);

    // The capture-pane reply: a %begin/%end block of plain pane content. It is
    // not a window list, so it routes to the queued pane (%5), prefixed with a
    // clear+home so it paints from the top-left.
    try s.feed("%begin 1 1 0\nline-a\nline-b\n%end 1 1 0\n");
    try std.testing.expectEqual(@as(usize, 5), col.last_pane);
    try std.testing.expectEqualSlices(u8, "\x1b[2J\x1b[Hline-a\r\nline-b", col.buf.items);
}

test "EventSink default is a silent no-op" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s.deinit();
    // No events sink set; these must not crash.
    try s.feed("%window-renamed @1 x\n");
    try s.feed("%window-pane-changed @1 %2\n");
}

test "list-panes reply drives onPaneMeta per pane" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var log = EventLog{ .alloc = std.testing.allocator };
    defer log.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s.deinit();
    s.events = log.eventSink();

    // Reply to: list-panes -s -F "#{pane_id}\t#{pane_current_path}\t#{pane_current_command}"
    try s.feed(
        "%begin 9 9 0\n" ++
            "%1\t/home/u/proj\tnvim\n" ++
            "%2\t/var/log\ttail\n" ++
            "%end 9 9 0\n",
    );

    try std.testing.expectEqual(@as(usize, 2), log.pane_meta_count);
    try std.testing.expectEqual(@as(?usize, 2), log.last_pane_meta_id);
    try std.testing.expectEqualStrings("/var/log", log.last_pane_meta_path.items);
    try std.testing.expectEqualStrings("tail", log.last_pane_meta_cmd.items);
}

test "a pending capture does not steal a list-panes reply (startup ordering)" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var log = EventLog{ .alloc = std.testing.allocator };
    defer log.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s.deinit();
    s.events = log.eventSink();

    // Captures are queued (as during attach reconcile) BEFORE the list-panes
    // reply arrives. The reply must be parsed as pane metadata, NOT consumed as
    // a capture seed, and the capture queue must stay intact.
    try s.capturePane(1);
    try s.capturePane(2);
    try s.feed("%begin 7 7 0\n%1\t/home/u\tnvim\n%2\t/var/log\ttail\n%end 7 7 0\n");

    try std.testing.expectEqual(@as(usize, 2), log.pane_meta_count);
    try std.testing.expectEqual(@as(usize, 2), s.capture_queue.items.len); // untouched
    try std.testing.expectEqual(@as(usize, 0), col.buf.items.len); // no capture seed written
}

test "a realistic capture reply is seeded even with pane-list-like ids elsewhere" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var log = EventLog{ .alloc = std.testing.allocator };
    defer log.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s.deinit();
    s.events = log.eventSink();

    try s.capturePane(5);
    // Real scrollback: NOT every line is `%<id>\t..`, so it's a capture, not pane-list.
    try s.feed("%begin 1 1 0\n$ ls\nfile.txt  %notapaneline\n%end 1 1 0\n");

    try std.testing.expectEqual(@as(usize, 0), log.pane_meta_count); // not pane-list
    try std.testing.expectEqual(@as(usize, 0), s.capture_queue.items.len); // capture consumed
    try std.testing.expect(std.mem.indexOf(u8, col.buf.items, "file.txt") != null); // seeded
}

test "start enqueues a list-panes metadata query" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s.deinit();
    try s.start();
    try std.testing.expect(std.mem.indexOf(u8, s.cmds.items, "list-panes -s -F") != null);
}

test "applyPaneList skips malformed lines and counts only valid pane-list entries" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var log = EventLog{ .alloc = std.testing.allocator };
    defer log.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s.deinit();
    s.events = log.eventSink();

    // All non-empty lines have the %<digits>\t shape (pass isPaneListReply), but
    // applyPaneList's deeper per-line checks filter the malformed ones:
    //   blank line              — skipped (ignored by both predicates)
    //   %3\t/only-one-tab      — skipped by applyPaneList (missing second tab)
    //   %7\t/home\tbash        — valid → pane_meta_count == 1
    try s.feed(
        "%begin 5 5 0\n" ++
            "\n" ++
            "%3\t/only-one-tab\n" ++
            "%7\t/home\tbash\n" ++
            "%end 5 5 0\n",
    );

    try std.testing.expectEqual(@as(usize, 1), log.pane_meta_count);
    try std.testing.expectEqual(@as(?usize, 7), log.last_pane_meta_id);
    try std.testing.expectEqualStrings("/home", log.last_pane_meta_path.items);
    try std.testing.expectEqualStrings("bash", log.last_pane_meta_cmd.items);
}
