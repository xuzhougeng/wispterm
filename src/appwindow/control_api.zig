//! Agent terminal control (wisptermctl) API and UI-published caches.

const std = @import("std");
const Surface = @import("../Surface.zig");
const remote = @import("../remote_client.zig");
const remote_snapshot = @import("../remote_snapshot.zig");
const ctl_control = @import("../ctl/control.zig");
const ctl_protocol = @import("../ctl/protocol.zig");
const surface_registry = @import("../surface_registry.zig");
const window_backend = @import("../platform/window_backend.zig");
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

// --- spawn (new-tab) queue: server thread enqueues, UI thread drains ---
// Tab creation touches threadlocal tab state + GPU resources, so it can't run on
// the ctl server thread. The server copies cwd+command into this queue and wakes
// the UI loop; drainSpawnQueue() (render tick) does the actual spawn and records
// the new surface id against the request's ticket for `spawn-result`.
pub const SpawnRequest = struct {
    cwd: []const u8,
    command: []const u8,
    /// Agent kind label ("" = none): the handler seeds the new surface's
    /// screen-detection identity with it.
    kind: []const u8,
    split: ctl_protocol.SpawnSplit,
};
/// UI-thread spawn handler: returns the new surface (null on failure).
pub const SpawnFn = *const fn (req: SpawnRequest) ?*Surface;
var g_spawn_handler: ?SpawnFn = null;
var g_spawn_mutex: std.Thread.Mutex = .{};
const SpawnItem = struct { ticket: u32, cwd: []u8, command: []u8, kind: []u8, split: ctl_protocol.SpawnSplit }; // page_allocator-owned
var g_spawn_queue: std.ArrayListUnmanaged(SpawnItem) = .empty;
var g_spawn_next_ticket: u32 = 1;
// ponytail: bounded so a wedged UI thread can't grow this without limit; 32
// queued tab spawns is far past any real burst. Raise if it ever bites.
const MAX_SPAWN_QUEUE = 32;

/// Outcome of a drained spawn, kept in a small ring so `spawn-result` can be
/// polled after the fact. Written by the UI thread, read by the server thread,
/// both under g_spawn_mutex.
const SpawnOutcome = struct { ticket: u32, surface_id: [16]u8, ok: bool };
const MAX_SPAWN_OUTCOMES = 64;
var g_spawn_outcomes: [MAX_SPAWN_OUTCOMES]SpawnOutcome = undefined;
var g_spawn_outcome_count: usize = 0;
var g_spawn_outcome_next: usize = 0;

pub fn setSpawnHandler(h: SpawnFn) void {
    g_spawn_handler = h;
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
    surface.queuePtyWrite(data) catch |err| {
        std.log.scoped(.control).warn(
            "dropped control write ({d} bytes): {s}",
            .{ data.len, @errorName(err) },
        );
        return false;
    };
    return true;
}

fn ctlUiState(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror!?[]u8 {
    _ = ctx;
    g_ctl_ui_state_mutex.lock();
    defer g_ctl_ui_state_mutex.unlock();
    if (g_ctl_ui_state_json.len == 0) return null;
    return try allocator.dupe(u8, g_ctl_ui_state_json);
}

/// Server thread: queue a new-terminal request for the UI thread, then wake it.
/// Returns the ticket to poll with `spawn-result`, or null if no handler is
/// wired up or the queue is full.
fn ctlSpawn(ctx: *anyopaque, cwd: []const u8, command: []const u8, opts: ctl_control.SpawnOptions) ?u32 {
    _ = ctx;
    if (g_spawn_handler == null) return null;
    const ticket = enqueueSpawn(cwd, command, opts) orelse return null;
    window_backend.postWakeup();
    return ticket;
}

fn enqueueSpawn(cwd: []const u8, command: []const u8, opts: ctl_control.SpawnOptions) ?u32 {
    const a = std.heap.page_allocator;
    g_spawn_mutex.lock();
    defer g_spawn_mutex.unlock();
    if (g_spawn_queue.items.len >= MAX_SPAWN_QUEUE) return null;
    const cwd_owned = a.dupe(u8, cwd) catch return null;
    errdefer a.free(cwd_owned);
    const cmd_owned = a.dupe(u8, command) catch return null;
    errdefer a.free(cmd_owned);
    const kind_owned = a.dupe(u8, opts.kind) catch return null;
    errdefer a.free(kind_owned);
    const ticket = g_spawn_next_ticket;
    g_spawn_queue.append(a, .{ .ticket = ticket, .cwd = cwd_owned, .command = cmd_owned, .kind = kind_owned, .split = opts.split }) catch return null;
    g_spawn_next_ticket +%= 1;
    if (g_spawn_next_ticket == 0) g_spawn_next_ticket = 1;
    return ticket;
}

fn recordSpawnOutcome(ticket: u32, surface: ?*Surface) void {
    var outcome = SpawnOutcome{ .ticket = ticket, .surface_id = undefined, .ok = surface != null };
    if (surface) |s| {
        outcome.surface_id = s.remote_id;
    } else {
        @memset(&outcome.surface_id, 0);
    }
    g_spawn_mutex.lock();
    defer g_spawn_mutex.unlock();
    g_spawn_outcomes[g_spawn_outcome_next] = outcome;
    g_spawn_outcome_next = (g_spawn_outcome_next + 1) % MAX_SPAWN_OUTCOMES;
    if (g_spawn_outcome_count < MAX_SPAWN_OUTCOMES) g_spawn_outcome_count += 1;
}

/// Server thread: JSON for a spawn ticket (see `Control.VTable.spawn_result`).
fn ctlSpawnResult(ctx: *anyopaque, allocator: std.mem.Allocator, ticket: u32) anyerror!?[]u8 {
    _ = ctx;
    g_spawn_mutex.lock();
    defer g_spawn_mutex.unlock();
    for (g_spawn_outcomes[0..g_spawn_outcome_count]) |o| {
        if (o.ticket != ticket) continue;
        if (!o.ok) return try allocator.dupe(u8, "{\"failed\":true}");
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);
        try out.appendSlice(allocator, "{\"surfaceId\":\"");
        try remote.appendJsonString(&out, allocator, o.surface_id[0..]);
        try out.appendSlice(allocator, "\"}");
        return try out.toOwnedSlice(allocator);
    }
    for (g_spawn_queue.items) |item| {
        if (item.ticket == ticket) return try allocator.dupe(u8, "{\"pending\":true}");
    }
    // Tickets are handed out before the queue is drained, so a ticket below
    // the counter that is in neither place was spawned before this process
    // tracked outcomes, or is simply too old for the ring.
    return null;
}

/// UI thread: spawn every queued terminal. Called from the render loop. No-op
/// when the queue is empty or no handler is registered.
pub fn drainSpawnQueue() void {
    const handler = g_spawn_handler orelse return;
    const a = std.heap.page_allocator;
    g_spawn_mutex.lock();
    var items = g_spawn_queue; // move ownership out; process unlocked
    g_spawn_queue = .empty;
    g_spawn_mutex.unlock();
    defer items.deinit(a);
    for (items.items) |item| {
        const surface = handler(.{ .cwd = item.cwd, .command = item.command, .kind = item.kind, .split = item.split });
        recordSpawnOutcome(item.ticket, surface);
        a.free(item.cwd);
        a.free(item.command);
        a.free(item.kind);
    }
}

pub fn clearSpawnQueue() void {
    const a = std.heap.page_allocator;
    g_spawn_mutex.lock();
    defer g_spawn_mutex.unlock();
    for (g_spawn_queue.items) |item| {
        a.free(item.cwd);
        a.free(item.command);
        a.free(item.kind);
    }
    g_spawn_queue.deinit(a);
    g_spawn_queue = .empty;
}

/// Server thread: the surface's published agent detection as JSON. Reads the
/// cross-thread mirror, so no UI-thread state is touched.
fn ctlAgentState(ctx: *anyopaque, allocator: std.mem.Allocator, id: []const u8) anyerror!?[]u8 {
    _ = ctx;
    const ptr = surface_registry.acquireById(id) orelse return null;
    defer surface_registry.release();
    const surface: *Surface = @ptrCast(@alignCast(ptr));
    const det = surface.agentDetectionShared();
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"id\":\"");
    try remote.appendJsonString(&out, allocator, id);
    try out.append(allocator, '"');
    try surface_snapshots.appendAgentDetectionValuesJson(allocator, &out, det);
    try out.append(allocator, '}');
    return try out.toOwnedSlice(allocator);
}

const ctl_vtable = ctl_control.Control.VTable{
    .list_panes = ctlListPanes,
    .get_text = ctlGetText,
    .send_text = ctlSendText,
    .ui_state = ctlUiState,
    .spawn = ctlSpawn,
    .agent_state = ctlAgentState,
    .spawn_result = ctlSpawnResult,
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

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try appendPanesJson(std.testing.allocator, &out);

    try std.testing.expectEqualStrings("{\"activeTab\":0,\"tabs\":[]}", out.items);
}

test "ctl surface callbacks reject an unregistered id without dereferencing" {
    const c = control();
    try std.testing.expect((try c.getText(std.testing.allocator, "missing", null)) == null);
    try std.testing.expect(!c.sendText("missing", "x"));
}

var g_test_spawn_log: std.ArrayListUnmanaged(u8) = .empty;
fn testSpawnHandler(req: SpawnRequest) ?*Surface {
    g_test_spawn_log.appendSlice(std.testing.allocator, req.cwd) catch {};
    g_test_spawn_log.append(std.testing.allocator, '|') catch {};
    g_test_spawn_log.appendSlice(std.testing.allocator, req.command) catch {};
    g_test_spawn_log.append(std.testing.allocator, '|') catch {};
    g_test_spawn_log.appendSlice(std.testing.allocator, req.kind) catch {};
    g_test_spawn_log.append(std.testing.allocator, '|') catch {};
    g_test_spawn_log.appendSlice(std.testing.allocator, req.split.label()) catch {};
    g_test_spawn_log.append(std.testing.allocator, ';') catch {};
    return null; // no real surface in a unit test → recorded as failed
}

test "spawn queue enqueues and drains in order to the handler" {
    defer {
        g_test_spawn_log.deinit(std.testing.allocator);
        g_test_spawn_log = .empty;
        g_spawn_handler = null;
        clearSpawnQueue();
    }
    // No handler → reject (don't accumulate undrained work).
    g_spawn_handler = null;
    try std.testing.expect(ctlSpawn(&g_ctl_ctx, "/a", "bash", .{}) == null);

    setSpawnHandler(testSpawnHandler);
    const t1 = enqueueSpawn("/a", "bash", .{}).?;
    const t2 = enqueueSpawn("", "codex -m x", .{ .kind = "codex", .split = .right }).?;
    try std.testing.expect(t2 != t1);
    // Queued but not yet drained: pending.
    const pending = (try ctlSpawnResult(&g_ctl_ctx, std.testing.allocator, t1)).?;
    defer std.testing.allocator.free(pending);
    try std.testing.expectEqualStrings("{\"pending\":true}", pending);

    drainSpawnQueue();
    try std.testing.expectEqualStrings("/a|bash||;|codex -m x|codex|right;", g_test_spawn_log.items);

    // Drained: the handler returned no surface, so the ticket reports failure;
    // a ticket never issued is unknown.
    const failed = (try ctlSpawnResult(&g_ctl_ctx, std.testing.allocator, t2)).?;
    defer std.testing.allocator.free(failed);
    try std.testing.expectEqualStrings("{\"failed\":true}", failed);
    try std.testing.expect((try ctlSpawnResult(&g_ctl_ctx, std.testing.allocator, t2 + 1000)) == null);

    g_spawn_mutex.lock();
    defer g_spawn_mutex.unlock();
    try std.testing.expectEqual(@as(usize, 0), g_spawn_queue.items.len);
}
