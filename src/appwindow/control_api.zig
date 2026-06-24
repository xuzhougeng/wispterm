//! Agent terminal control (wisptermctl) API and UI-published caches.

const std = @import("std");
const Surface = @import("../Surface.zig");
const remote = @import("../remote_client.zig");
const remote_snapshot = @import("../remote_snapshot.zig");
const ctl_control = @import("../ctl/control.zig");
const surface_registry = @import("../surface_registry.zig");
const active_tab_state = @import("active_tab.zig");
const tab = @import("tab.zig");
const surface_snapshots = @import("surface_snapshots.zig");

var g_agent_control_enabled = std.atomic.Value(bool).init(false);
var g_ctl_ctx: u8 = 0;
var g_ctl_panes_mutex: std.Thread.Mutex = .{};
var g_ctl_panes_json: []u8 = &.{}; // page_allocator-owned latest panes JSON
// Atomic: syncPanes runs from every window's render thread (the panes cache
// is process-global, last-writer-wins - acceptable, matching the relay layout
// sync). The timestamp must be touched atomically to avoid a data race.
var g_ctl_panes_last_ms = std.atomic.Value(i64).init(0);

// Overlay semantic state for `ui-state`, published the same way as panes: the UI
// thread serializes the threadlocal command-center globals on the render tick,
// the ctl server thread only ever reads this buffer under the mutex.
var g_ctl_ui_state_mutex: std.Thread.Mutex = .{};
var g_ctl_ui_state_json: []u8 = &.{}; // page_allocator-owned latest ui-state JSON
var g_ctl_ui_state_last_ms = std.atomic.Value(i64).init(0);

const ctl_default_rows: u32 = 1000;

pub const BuildUiStateJsonFn = *const fn (allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) anyerror!void;
var g_build_ui_state_json: ?BuildUiStateJsonFn = null;

pub fn setUiStateBuilder(builder: BuildUiStateJsonFn) void {
    g_build_ui_state_json = builder;
}

pub fn enable() void {
    g_agent_control_enabled.store(true, .release);
}

fn ctlListPanes(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror!?[]u8 {
    _ = ctx;
    g_ctl_panes_mutex.lock();
    defer g_ctl_panes_mutex.unlock();
    if (g_ctl_panes_json.len == 0) return null;
    return try allocator.dupe(u8, g_ctl_panes_json);
}

fn ctlGetText(ctx: *anyopaque, allocator: std.mem.Allocator, id: []const u8, recent: ?u32) anyerror!?[]u8 {
    _ = ctx;
    // Cross-platform + UAF-safe: the registry blocks Surface.deinit for the
    // duration of the snapshot, and the id match rejects a reused pointer.
    const ptr = surface_registry.acquireById(id) orelse return null;
    defer surface_registry.release();
    const surface: *Surface = @ptrCast(@alignCast(ptr));
    const want: usize = if (recent) |r| r else ctl_default_rows;
    const rows = @min(want, remote_snapshot.default_max_history_rows);
    return try surface_snapshots.buildRemoteSurfaceSnapshot(allocator, surface, rows);
}

fn ctlSendText(ctx: *anyopaque, id: []const u8, data: []const u8) bool {
    _ = ctx;
    const ptr = surface_registry.acquireById(id) orelse return false;
    defer surface_registry.release();
    const surface: *Surface = @ptrCast(@alignCast(ptr));
    surface.queuePtyWrite(data);
    return true;
}

fn ctlUiState(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror!?[]u8 {
    _ = ctx;
    g_ctl_ui_state_mutex.lock();
    defer g_ctl_ui_state_mutex.unlock();
    if (g_ctl_ui_state_json.len == 0) return null;
    return try allocator.dupe(u8, g_ctl_ui_state_json);
}

const ctl_vtable = ctl_control.Control.VTable{
    .list_panes = ctlListPanes,
    .get_text = ctlGetText,
    .send_text = ctlSendText,
    .ui_state = ctlUiState,
};

/// The Control the agent-control server drives. Backed by process-global state,
/// so the dummy ctx is unused.
pub fn control() ctl_control.Control {
    return .{ .ctx = &g_ctl_ctx, .vtable = &ctl_vtable };
}

pub fn clearPanesCache() void {
    g_ctl_panes_mutex.lock();
    defer g_ctl_panes_mutex.unlock();
    if (g_ctl_panes_json.len != 0) std.heap.page_allocator.free(g_ctl_panes_json);
    g_ctl_panes_json = &.{};
}

/// UI-thread: publish a fresh panes JSON snapshot (throttled). Called from the
/// render loop next to syncRemoteLayout. No-op unless ctl is enabled.
pub fn syncPanes(allocator: std.mem.Allocator) void {
    if (!g_agent_control_enabled.load(.acquire)) return;
    const now = std.time.milliTimestamp();
    if (now - g_ctl_panes_last_ms.load(.monotonic) < 200) return;
    g_ctl_panes_last_ms.store(now, .monotonic);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    appendPanesJson(allocator, &out) catch return;

    const owned = std.heap.page_allocator.dupe(u8, out.items) catch return;
    g_ctl_panes_mutex.lock();
    defer g_ctl_panes_mutex.unlock();
    if (g_ctl_panes_json.len != 0) std.heap.page_allocator.free(g_ctl_panes_json);
    g_ctl_panes_json = owned;
}

pub fn clearUiStateCache() void {
    g_ctl_ui_state_mutex.lock();
    defer g_ctl_ui_state_mutex.unlock();
    if (g_ctl_ui_state_json.len != 0) std.heap.page_allocator.free(g_ctl_ui_state_json);
    g_ctl_ui_state_json = &.{};
}

/// UI-thread: publish a fresh overlay ui-state JSON snapshot (throttled). Called
/// from the render loop next to syncPanes. No-op unless ctl is enabled.
pub fn syncUiState(allocator: std.mem.Allocator) void {
    if (!g_agent_control_enabled.load(.acquire)) return;
    const build_ui_state_json = g_build_ui_state_json orelse return;
    const now = std.time.milliTimestamp();
    if (now - g_ctl_ui_state_last_ms.load(.monotonic) < 200) return;
    g_ctl_ui_state_last_ms.store(now, .monotonic);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    build_ui_state_json(allocator, &out) catch return;

    const owned = std.heap.page_allocator.dupe(u8, out.items) catch return;
    g_ctl_ui_state_mutex.lock();
    defer g_ctl_ui_state_mutex.unlock();
    if (g_ctl_ui_state_json.len != 0) std.heap.page_allocator.free(g_ctl_ui_state_json);
    g_ctl_ui_state_json = owned;
}

pub fn buildPanesJson(allocator: std.mem.Allocator) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try appendPanesJson(allocator, &out);
    return out.toOwnedSlice(allocator);
}

/// Lightweight panes listing for the agent-control API. Mirrors
/// buildRemoteLayoutJson's terminal branch but omits the heavy per-surface
/// scrollback snapshot (that is get-text's job) and adds the surface cwd.
/// Non-terminal tabs (AI chat / history / etc.) appear as a minimal entry so
/// the listing is complete. UI-thread only (reads threadlocal tab state).
fn appendPanesJson(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
    try out.appendSlice(allocator, "{\"activeTab\":");
    try out.print(allocator, "{d}", .{active_tab_state.g_active_tab});
    try out.appendSlice(allocator, ",\"tabs\":[");

    var wrote_tab = false;
    for (0..tab.g_tab_count) |tab_index| {
        const tab_state = tab.g_tabs[tab_index] orelse continue;
        if (wrote_tab) try out.append(allocator, ',');
        wrote_tab = true;

        if (tab_state.kind != .terminal) {
            try out.appendSlice(allocator, "{\"index\":");
            try out.print(allocator, "{d}", .{tab_index});
            try out.appendSlice(allocator, ",\"title\":\"");
            try remote.appendJsonString(out, allocator, tab_state.getTitle());
            try out.appendSlice(allocator, "\",\"kind\":\"");
            try remote.appendJsonString(out, allocator, @tagName(tab_state.kind));
            try out.appendSlice(allocator, "\",\"surfaces\":[]}");
            continue;
        }

        try out.appendSlice(allocator, "{\"index\":");
        try out.print(allocator, "{d}", .{tab_index});
        try out.appendSlice(allocator, ",\"title\":\"");
        try remote.appendJsonString(out, allocator, tab_state.getTitle());
        try out.appendSlice(allocator, "\",\"kind\":\"terminal\",\"focusedSurfaceId\":\"");
        if (tab_state.focusedSurface()) |focused|
            try remote.appendJsonString(out, allocator, focused.remote_id[0..]);
        try out.appendSlice(allocator, "\",\"surfaces\":[");

        var spatial = tab_state.tree.spatial(allocator) catch null;
        defer if (spatial) |*sp| sp.deinit(allocator);

        var wrote_surface = false;
        var it = tab_state.tree.surfaces();
        while (it.next()) |entry| {
            if (wrote_surface) try out.append(allocator, ',');
            wrote_surface = true;

            try out.appendSlice(allocator, "{\"id\":\"");
            try remote.appendJsonString(out, allocator, entry.surface.remote_id[0..]);
            try out.appendSlice(allocator, "\",\"title\":\"");
            try remote.appendJsonString(out, allocator, entry.surface.getTitle());
            try out.appendSlice(allocator, "\",\"focused\":");
            try out.appendSlice(allocator, if (entry.handle == tab_state.focused) "true" else "false");
            try surface_snapshots.appendAgentDetectionJson(allocator, out, entry.surface);
            try out.appendSlice(allocator, ",\"cols\":");
            try out.print(allocator, "{d}", .{entry.surface.size.grid.cols});
            try out.appendSlice(allocator, ",\"rows\":");
            try out.print(allocator, "{d}", .{entry.surface.size.grid.rows});
            var cx: usize = 0;
            var cy: usize = 0;
            {
                entry.surface.render_state.mutex.lock();
                defer entry.surface.render_state.mutex.unlock();
                cx = entry.surface.terminal.screens.active.cursor.x;
                cy = entry.surface.terminal.screens.active.cursor.y;
            }
            try out.appendSlice(allocator, ",\"cursorX\":");
            try out.print(allocator, "{d}", .{cx});
            try out.appendSlice(allocator, ",\"cursorY\":");
            try out.print(allocator, "{d}", .{cy});
            try out.appendSlice(allocator, ",\"cwd\":\"");
            if (entry.surface.getCwd()) |cwd| try remote.appendJsonString(out, allocator, cwd);
            try out.append(allocator, '"');

            if (spatial) |sp| {
                const slot = sp.slots[entry.handle.idx()];
                try out.appendSlice(allocator, ",\"x\":");
                try out.print(allocator, "{d:.5}", .{@as(f64, @floatCast(slot.x))});
                try out.appendSlice(allocator, ",\"y\":");
                try out.print(allocator, "{d:.5}", .{@as(f64, @floatCast(slot.y))});
                try out.appendSlice(allocator, ",\"w\":");
                try out.print(allocator, "{d:.5}", .{@as(f64, @floatCast(slot.width))});
                try out.appendSlice(allocator, ",\"h\":");
                try out.print(allocator, "{d:.5}", .{@as(f64, @floatCast(slot.height))});
            } else {
                try out.appendSlice(allocator, ",\"x\":0,\"y\":0,\"w\":1,\"h\":1");
            }

            try out.append(allocator, '}');
        }

        try out.appendSlice(allocator, "]}");
    }

    try out.appendSlice(allocator, "]}");
}

test "control api panes json includes empty tab topology" {
    const saved_active = active_tab_state.g_active_tab;
    const saved_count = tab.g_tab_count;
    defer {
        active_tab_state.g_active_tab = saved_active;
        tab.g_tab_count = saved_count;
    }
    active_tab_state.g_active_tab = 0;
    tab.g_tab_count = 0;

    const json = try buildPanesJson(std.testing.allocator);
    defer std.testing.allocator.free(json);

    try std.testing.expectEqualStrings("{\"activeTab\":0,\"tabs\":[]}", json);
}

test "ctl surface callbacks reject an unregistered id without dereferencing" {
    const c = control();
    try std.testing.expect((try c.getText(std.testing.allocator, "missing", null)) == null);
    try std.testing.expect(!c.sendText("missing", "x"));
}
