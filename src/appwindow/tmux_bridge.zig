//! UI bridge for tmux control mode (Phase 3c-2). Sits between the pure
//! `tmux.Session` model and WispTerm's tab/Surface UI. Owns the `Session` and
//! `PaneMap`, implements `Session.EventSink` to drive tabs/splits, and supplies
//! the per-pane `Surface` factory for `SplitTree.fromTmuxLayout`.
//!
//! POSIX-only: it materializes panes via `Pty.openVirtual` (socketpair). It is
//! referenced only from posix-target builds (registered in `test_main.zig`
//! under the `!= .windows` guard; wired into `AppWindow` by Phase 3d). A real
//! `Surface` cannot be built in a headless test (its `Renderer` needs the GPU
//! backend), so the reconcile path is compile-checked here and GUI-verified in
//! 3d; only the Surface-free helpers are unit-tested.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Surface = @import("../Surface.zig");
const SplitTree = @import("../split_tree.zig");
const Config = @import("../config.zig");
const Pty = @import("../platform/pty.zig").Pty;
const session_mod = @import("../tmux/session.zig");
const pane_mod = @import("../tmux/pane.zig");
const layout = @import("../tmux/layout.zig");
const tab = @import("tab.zig");
const active_tab_state = @import("active_tab.zig");

const Session = session_mod.Session;
const PaneMap = pane_mod.PaneMap;
const TabState = tab.TabState;

pub const TmuxBridge = struct {
    alloc: Allocator,
    session: Session,
    panes: PaneMap,
    // Config snapshot used when materializing a pane's Surface.
    scrollback_limit: u32,
    cursor_style: Config.CursorStyle,
    cursor_blink: bool,

    /// Heap-allocate + wire the bridge. The bridge is self-referential (its
    /// `PaneSink`/`EventSink` close over `&self.panes` / `self`), so it must be
    /// pinned — always use `create`/`destroy`, never move a `TmuxBridge`.
    pub fn create(
        alloc: Allocator,
        cols: u16,
        rows: u16,
        scrollback_limit: u32,
        cursor_style: Config.CursorStyle,
        cursor_blink: bool,
    ) Allocator.Error!*TmuxBridge {
        const self = try alloc.create(TmuxBridge);
        errdefer alloc.destroy(self);
        self.alloc = alloc;
        self.panes = PaneMap.init(alloc);
        self.scrollback_limit = scrollback_limit;
        self.cursor_style = cursor_style;
        self.cursor_blink = cursor_blink;
        self.session = Session.init(alloc, self.panes.sink(), cols, rows);
        self.session.events = self.eventSink();
        return self;
    }

    /// Tear down the controller side. Closes every pane's `controller_fd`
    /// (giving each Surface an EOF) and frees the Session. Does NOT destroy the
    /// tab Surfaces — those are owned by their tabs/`SplitTree`s and are torn
    /// down by the AppWindow's tab lifecycle.
    pub fn destroy(self: *TmuxBridge) void {
        self.session.deinit();
        self.panes.deinit();
        self.alloc.destroy(self);
    }

    fn eventSink(self: *TmuxBridge) Session.EventSink {
        return .{
            .ctx = self,
            .onLayoutChange = onLayoutChange,
            .onWindowRenamed = onWindowRenamed,
            .onWindowClose = onWindowClose,
            .onActivePaneChanged = onActivePaneChanged,
        };
    }

    // ----- EventSink: layout reconcile -----

    fn onLayoutChange(ctx: *anyopaque, window_id: usize, root: *const layout.Node) void {
        const self: *TmuxBridge = @ptrCast(@alignCast(ctx));
        self.reconcileWindow(window_id, root) catch |err| {
            std.debug.print("tmux: reconcile window @{d} failed: {}\n", .{ window_id, err });
        };
    }

    fn reconcileWindow(self: *TmuxBridge, window_id: usize, root: *const layout.Node) !void {
        const t = self.findOrCreateTab(window_id) orelse return error.NoTabSlot;

        // 1. Build the new tree. The factory reuses surfaces by pane id (ref'd
        //    for the new tree) or creates new virtual-PTY panes.
        var fctx = FactoryCtx{ .bridge = self, .root = root };
        const new_tree = try SplitTree.fromTmuxLayout(self.alloc, root, &fctx, FactoryCtx.make);

        // 2. Snapshot the old window's pane ids (reverse-lookup each old leaf).
        var old_ids: std.ArrayListUnmanaged(usize) = .empty;
        defer old_ids.deinit(self.alloc);
        {
            var it = t.tree.iterator();
            while (it.next()) |entry| {
                if (self.panes.findIdBySurface(entry.surface)) |id| {
                    try old_ids.append(self.alloc, id);
                }
            }
        }

        // 3. Swap. The old tree's deinit unrefs vanished surfaces to
        //    destruction; reused surfaces survive (the new tree holds a ref).
        var old_tree = t.tree;
        t.tree = new_tree;
        old_tree.deinit();

        // 4. Drop panes gone from the new layout (closes their controller_fd).
        for (old_ids.items) |id| {
            if (findLeaf(root, id) == null) self.panes.removePane(id);
        }

        // 5. Resolve focus to the active pane's leaf, if in this tab.
        self.refocusActivePane(t);

        std.debug.print("tmux: reconciled window @{d} -> tab, tree nodes={d}\n", .{ window_id, t.tree.nodes.len });
    }

    /// Per-pane Surface factory for `SplitTree.fromTmuxLayout`. Reuse → `ref()`;
    /// new → open a virtual PTY + `Surface.initVirtual` + register in PaneMap.
    /// Returns one ref transferred to the new tree, or null on failure (the
    /// reconcile aborts and keeps the old tree).
    const FactoryCtx = struct {
        bridge: *TmuxBridge,
        root: *const layout.Node,

        fn make(ctx: *anyopaque, pane_id: usize) ?*Surface {
            const fc: *FactoryCtx = @ptrCast(@alignCast(ctx));
            const self = fc.bridge;

            // Reuse: hand the new tree a fresh ref to the existing surface.
            if (self.panes.find(pane_id)) |p| {
                if (p.surface) |op| {
                    const s: *Surface = @ptrCast(@alignCast(op));
                    return s.ref();
                }
            }

            // New pane: cell size comes from the layout leaf.
            const leaf = findLeaf(fc.root, pane_id) orelse return null;
            const cols: u16 = @intCast(@max(@as(u32, 1), leaf.w));
            const rows: u16 = @intCast(@max(@as(u32, 1), leaf.h));

            const pair = Pty.openVirtual(.{ .ws_col = cols, .ws_row = rows }) catch return null;
            // On `initVirtual` failure, its errdefer deinits the adopted pty
            // (master + cancel pipe); we still own and must close controller_fd.
            const surface = Surface.initVirtual(
                self.alloc,
                cols,
                rows,
                pair.pty,
                self.scrollback_limit,
                self.cursor_style,
                self.cursor_blink,
            ) catch {
                std.posix.close(pair.controller_fd);
                return null;
            };
            surface.attachRemoteClient(tab.g_remote_client);

            self.panes.addPane(pane_id, pair.controller_fd) catch {
                surface.unref(self.alloc); // ref 1 -> 0: destroys it (deinits pty)
                std.posix.close(pair.controller_fd);
                return null;
            };
            self.panes.setSurface(pane_id, surface);
            // NOTE: capture-pane scrollback seeding (Session.capturePane) is
            // intentionally NOT called here yet — feeding the captured text to a
            // surface whose grid size doesn't match the tmux pane garbles the
            // render. Activate once client/pane size-sync (resize) lands so the
            // surface grid matches tmux's pane width.
            return surface; // ref 1, transferred to the tree
        }
    };

    fn refocusActivePane(self: *TmuxBridge, t: *TabState) void {
        const active = self.session.active_pane orelse return;
        const p = self.panes.find(active) orelse return;
        const op = p.surface orelse return;
        const target: *Surface = @ptrCast(@alignCast(op));
        var it = t.tree.iterator();
        while (it.next()) |entry| {
            if (entry.surface == target) {
                t.focused = entry.handle;
                return;
            }
        }
    }

    // ----- EventSink: window events -----

    fn onWindowRenamed(_: *anyopaque, window_id: usize, name: []const u8) void {
        const idx = findTabIndexByWindowId(window_id) orelse return;
        const t = tab.g_tabs[idx] orelse return;
        const n = @min(name.len, t.tmux_name_buf.len);
        @memcpy(t.tmux_name_buf[0..n], name[0..n]);
        t.tmux_name_len = n;
    }

    fn onWindowClose(ctx: *anyopaque, window_id: usize) void {
        const self: *TmuxBridge = @ptrCast(@alignCast(ctx));
        const idx = findTabIndexByWindowId(window_id) orelse return;
        const t = tab.g_tabs[idx] orelse return;
        // Drop this window's panes from the PaneMap (closes their fds) before
        // closeTab destroys the surfaces. removePane never touches the surface.
        var it = t.tree.iterator();
        while (it.next()) |entry| {
            if (self.panes.findIdBySurface(entry.surface)) |id| self.panes.removePane(id);
        }
        // closeTab no-ops when this is the last tab; whole-connection teardown
        // for that case is a Phase 3d concern.
        tab.closeTab(idx, self.alloc);
    }

    fn onActivePaneChanged(ctx: *anyopaque, pane_id: usize) void {
        const self: *TmuxBridge = @ptrCast(@alignCast(ctx));
        const p = self.panes.find(pane_id) orelse return;
        const op = p.surface orelse return;
        const target: *Surface = @ptrCast(@alignCast(op));
        // Focus the owning tab's leaf; do NOT switch the active tab (tmux pane
        // focus is not the user's tab choice).
        var ti: usize = 0;
        while (ti < tab.g_tab_count) : (ti += 1) {
            const t = tab.g_tabs[ti] orelse continue;
            if (t.kind != .terminal) continue;
            var it = t.tree.iterator();
            while (it.next()) |entry| {
                if (entry.surface == target) {
                    t.focused = entry.handle;
                    return;
                }
            }
        }
    }

    // ----- tab lookup / creation -----

    fn findOrCreateTab(self: *TmuxBridge, window_id: usize) ?*TabState {
        if (findTabIndexByWindowId(window_id)) |idx| return tab.g_tabs[idx];
        if (tab.g_tab_count >= tab.MAX_TABS) return null;
        const t = self.alloc.create(TabState) catch return null;
        t.kind = .terminal;
        t.tree = .empty;
        t.focused = .root;
        t.ai_chat_session = null;
        t.ai_history_session = null;
        t.copilot_session = null;
        t.tmux_window_id = window_id;
        t.tmux_name_len = 0;
        tab.g_tabs[tab.g_tab_count] = t;
        active_tab_state.g_active_tab = tab.g_tab_count;
        tab.g_tab_count += 1;
        return t;
    }
};

/// Index of the tab mirroring this tmux window id, or null. Pure helper over the
/// thread-local tab model — unit-tested without any Surface.
fn findTabIndexByWindowId(window_id: usize) ?usize {
    var i: usize = 0;
    while (i < tab.g_tab_count) : (i += 1) {
        if (tab.g_tabs[i]) |t| {
            if (t.tmux_window_id == window_id) return i;
        }
    }
    return null;
}

/// The leaf for `pane_id` anywhere in a parsed layout tree, or null. Pure.
fn findLeaf(node: *const layout.Node, pane_id: usize) ?layout.Node.Leaf {
    switch (node.*) {
        .leaf => |l| return if (l.pane_id == pane_id) l else null,
        .split => |s| {
            for (s.children) |*child| {
                if (findLeaf(child, pane_id)) |found| return found;
            }
            return null;
        },
    }
}

// ----- tests (Surface-free only) -----

test "findLeaf locates a pane and reads its cell size" {
    var parsed = try layout.parse(std.testing.allocator, "80x24,0,0{40x24,0,0,1,39x24,41,0,2}");
    defer parsed.deinit();

    const l2 = findLeaf(&parsed.root, 2) orelse return error.NotFound;
    try std.testing.expectEqual(@as(u32, 39), l2.w);
    try std.testing.expectEqual(@as(u32, 24), l2.h);
    try std.testing.expect(findLeaf(&parsed.root, 99) == null);
}

test "findTabIndexByWindowId matches on tmux_window_id" {
    // Save/restore the thread-local tab model so the test is self-contained.
    const saved_tabs = tab.g_tabs;
    const saved_count = tab.g_tab_count;
    defer {
        tab.g_tabs = saved_tabs;
        tab.g_tab_count = saved_count;
    }

    var t0: TabState = .{ .tree = .empty };
    t0.kind = .terminal;
    t0.tmux_window_id = 5;
    var t1: TabState = .{ .tree = .empty };
    t1.kind = .terminal;
    t1.tmux_window_id = 9;

    tab.g_tabs = .{null} ** tab.MAX_TABS;
    tab.g_tabs[0] = &t0;
    tab.g_tabs[1] = &t1;
    tab.g_tab_count = 2;

    try std.testing.expectEqual(@as(?usize, 1), findTabIndexByWindowId(9));
    try std.testing.expectEqual(@as(?usize, 0), findTabIndexByWindowId(5));
    try std.testing.expectEqual(@as(?usize, null), findTabIndexByWindowId(7));
}
