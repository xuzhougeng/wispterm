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
    active_pane: ?usize = null,
    exited: bool = false,
    events: EventSink = .{},

    pub const Window = struct {
        id: usize,
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
        onActivePaneChanged: *const fn (ctx: *anyopaque, pane_id: usize) void = noActive,

        fn noLayout(_: *anyopaque, _: usize, _: *const layout.Node) void {}
        fn noRename(_: *anyopaque, _: usize, _: []const u8) void {}
        fn noClose(_: *anyopaque, _: usize) void {}
        fn noActive(_: *anyopaque, _: usize) void {}
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

    /// Enqueue the attach bootstrap: tell tmux our client size and ask for the
    /// window list. (Parsing the list-windows reply for complete initial
    /// enumeration is Phase 3; the live model is built from pushed
    /// notifications.)
    pub fn start(self: *Session) Allocator.Error!void {
        try self.enqueueResize();
        try self.cmds.appendSlice(self.alloc, "list-windows -F \"#{window_id} #{window_layout}\"\n");
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
};

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

const EventLog = struct {
    alloc: Allocator,
    layout_window: ?usize = null,
    layout_panes: usize = 0,
    renamed_window: ?usize = null,
    renamed_name: std.ArrayListUnmanaged(u8) = .empty,
    closed_window: ?usize = null,
    active_pane: ?usize = null,

    fn eventSink(self: *EventLog) Session.EventSink {
        return .{
            .ctx = self,
            .onLayoutChange = onLayout,
            .onWindowRenamed = onRenamed,
            .onWindowClose = onClose,
            .onActivePaneChanged = onActive,
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
    fn deinit(self: *EventLog) void {
        self.renamed_name.deinit(self.alloc);
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

test "EventSink default is a silent no-op" {
    var col = Collector{ .alloc = std.testing.allocator };
    defer col.deinit();
    var s = Session.init(std.testing.allocator, col.sink(), 80, 24);
    defer s.deinit();
    // No events sink set; these must not crash.
    try s.feed("%window-renamed @1 x\n");
    try s.feed("%window-pane-changed @1 %2\n");
}
