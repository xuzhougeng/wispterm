//! Shared surface snapshot helpers for remote and agent control paths.

const std = @import("std");
const Surface = @import("../Surface.zig");
const ai_chat = @import("../ai_chat.zig");
const agent_detector = @import("../agent_detector.zig");
const preview_diagnostics = @import("../preview_diagnostics.zig");
const remote = @import("../remote_client.zig");
const remote_snapshot = @import("../remote_snapshot.zig");
const surface_registry = @import("../surface_registry.zig");
const active_tab_state = @import("active_tab.zig");
const tab = @import("tab.zig");

threadlocal var g_agent_context_surface_id: [16]u8 = undefined;
threadlocal var g_agent_context_surface_id_len: usize = 0;

pub fn setAgentContextSurface(surface: *const Surface) void {
    @memcpy(g_agent_context_surface_id[0..], surface.remote_id[0..]);
    g_agent_context_surface_id_len = surface.remote_id.len;
}

pub fn agentContextSurfaceId() []const u8 {
    return g_agent_context_surface_id[0..g_agent_context_surface_id_len];
}

pub fn appendAgentDetectionJson(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    surface: ?*const Surface,
) !void {
    const detection: agent_detector.Detection = if (surface) |s| s.agent_detection else .{};
    try out.appendSlice(allocator, ",\"agentApp\":\"");
    try remote.appendJsonString(out, allocator, detection.appLabel());
    try out.appendSlice(allocator, "\",\"agentState\":\"");
    try remote.appendJsonString(out, allocator, detection.stateLabel());
    try out.appendSlice(allocator, "\",\"agentBadge\":\"");
    try remote.appendJsonString(out, allocator, detection.badge());
    try out.appendSlice(allocator, "\",\"agentConfidence\":");
    try out.print(allocator, "{d}", .{detection.confidence});
}

pub fn buildRemoteSurfaceSnapshot(allocator: std.mem.Allocator, surface: *Surface, max_history_rows: usize) ![]u8 {
    surface.render_state.mutex.lock();
    defer surface.render_state.mutex.unlock();
    return remote_snapshot.allocTerminalSnapshot(
        allocator,
        &surface.terminal,
        max_history_rows,
    );
}

pub fn activeSurfaceSnapshot(allocator: std.mem.Allocator) ?[]u8 {
    const surface = tab.activeSurface() orelse return null;
    // Jupyter-URL detection / web-remote mirror want the full scrollback, not the
    // smaller agent budget.
    return buildRemoteSurfaceSnapshot(allocator, surface, remote_snapshot.default_max_history_rows) catch null;
}

pub const AgentSurfaceLocation = struct {
    tab_index: usize,
    focused: bool,
};

pub fn findAgentSurfaceLocation(surface: *const Surface) ?AgentSurfaceLocation {
    for (0..tab.g_tab_count) |tab_index| {
        const tab_state = tab.g_tabs[tab_index] orelse continue;
        if (tab_state.kind != .terminal) continue;
        var it = tab_state.tree.surfaces();
        while (it.next()) |entry| {
            if (entry.surface == surface) {
                return .{
                    .tab_index = tab_index,
                    .focused = tab_index == active_tab_state.g_active_tab and entry.handle == tab_state.focused,
                };
            }
        }
    }
    return null;
}

pub fn makeAgentToolSurface(
    allocator: std.mem.Allocator,
    surface: *Surface,
    tab_index: usize,
    focused: bool,
) anyerror!ai_chat.ToolSurface {
    const snapshot = buildRemoteSurfaceSnapshot(allocator, surface, remote_snapshot.agent_max_history_rows) catch try allocator.dupe(u8, "");
    const ssh_conn = if (surface.launch_kind == .ssh) surface.ssh_connection else null;
    return ai_chat.ToolSurface.initOwned(
        allocator,
        surface.remote_id[0..],
        surface.getTitle(),
        surface.getCwd() orelse surface.getInitialCwd() orelse "",
        snapshot,
        .{
            .tab_index = tab_index,
            .focused = focused,
            .is_ssh = surface.launch_kind == .ssh,
            .is_wsl = surface.launch_kind == .wsl,
            .ssh_connection = ssh_conn,
            .agent_app = surface.agent_detection.app,
            .agent_state = surface.agent_detection.state,
            .agent_confidence = surface.agent_detection.confidence,
            .ptr = @ptrCast(surface),
        },
    );
}

pub fn collectAgentToolSnapshot(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror!ai_chat.ToolSnapshot {
    _ = ctx;
    var surfaces: std.ArrayListUnmanaged(ai_chat.ToolSurface) = .empty;
    errdefer {
        for (surfaces.items) |surface| surface.deinit(allocator);
        surfaces.deinit(allocator);
    }

    var active_tab = active_tab_state.g_active_tab;
    const context_surface_id = g_agent_context_surface_id[0..g_agent_context_surface_id_len];
    for (0..tab.g_tab_count) |tab_index| {
        const tab_state = tab.g_tabs[tab_index] orelse continue;
        if (tab_state.kind != .terminal) continue;
        var it = tab_state.tree.surfaces();
        while (it.next()) |entry| {
            const is_context = context_surface_id.len > 0 and std.mem.eql(u8, entry.surface.remote_id[0..], context_surface_id);
            if (is_context) active_tab = tab_index;
            const tool_surface = try makeAgentToolSurface(
                allocator,
                entry.surface,
                tab_index,
                is_context,
            );
            errdefer tool_surface.deinit(allocator);
            try surfaces.append(allocator, tool_surface);
        }
    }

    return .{
        .surfaces = try surfaces.toOwnedSlice(allocator),
        .active_tab = active_tab,
    };
}

pub fn agentSurfaceSnapshot(ctx: *anyopaque, allocator: std.mem.Allocator, surface_id: []const u8, surface_ptr: *anyopaque) anyerror![]u8 {
    _ = ctx;
    // Runs on the agent request worker with a pointer captured at request
    // start; the UI thread may have freed the surface since. The registry
    // guard blocks Surface.deinit for the duration of the snapshot. Matching
    // the captured id prevents a reused pointer from targeting a new surface.
    if (!surface_registry.acquire(surface_ptr, surface_id)) return error.SurfaceClosed;
    defer surface_registry.release();
    const surface: *Surface = @ptrCast(@alignCast(surface_ptr));
    return buildRemoteSurfaceSnapshot(allocator, surface, remote_snapshot.agent_max_history_rows);
}

pub fn agentWriteSurface(ctx: *anyopaque, surface_id: []const u8, surface_ptr: *anyopaque, data: []const u8) bool {
    _ = ctx;
    // Same worker-thread hazard as agentSurfaceSnapshot.
    if (!surface_registry.acquire(surface_ptr, surface_id)) return false;
    defer surface_registry.release();
    const surface: *Surface = @ptrCast(@alignCast(surface_ptr));
    surface.queuePtyWrite(data);
    return true;
}

test "agent surface callbacks reject a surface that is not registered as live" {
    // The agent request worker holds ToolSurface.ptr across an entire request
    // while the UI thread may free the surface at any time (close tab/split).
    // Both callbacks must refuse an unregistered pointer before touching any
    // Surface field. The stand-in below is zeroed, never-registered memory; if
    // a callback dereferences it the test crashes instead of erroring.
    var dummy_buf: [@sizeOf(Surface)]u8 align(@alignOf(Surface)) = @splat(0);
    const ptr: *anyopaque = @ptrCast(&dummy_buf);

    try std.testing.expectError(error.SurfaceClosed, agentSurfaceSnapshot(ptr, std.testing.allocator, "missing", ptr));
    try std.testing.expect(!agentWriteSurface(ptr, "missing", ptr, "x"));
}

pub fn agentSshConnectionForSurface(ctx: *anyopaque, surface_id: []const u8) ?Surface.SshConnection {
    _ = ctx;
    if (surface_id.len == 0) return null;
    // This runs on the agent request worker thread, but `g_tabs`/`g_tab_count`
    // are thread-local to the UI thread. A worker-thread call therefore sees an
    // empty tab list and resolves nothing — the root of copy_file's "connection
    // is unavailable" (#268). Log the tab count actually visible here so a log
    // capture distinguishes "empty thread-local view" from "surface_id mismatch".
    for (0..tab.g_tab_count) |tab_index| {
        const tab_state = tab.g_tabs[tab_index] orelse continue;
        if (tab_state.kind != .terminal) continue;
        var it = tab_state.tree.surfaces();
        while (it.next()) |entry| {
            const sfc = entry.surface;
            if (!std.mem.eql(u8, sfc.remote_id[0..], surface_id)) continue;
            preview_diagnostics.debug("agent-ssh-conn", &.{
                .{ .key = "stage", .value = "match" },
                .{ .key = "tabs", .value = if (tab.g_tab_count == 0) "0" else "n" },
                .{ .key = "has_conn", .value = if (sfc.ssh_connection != null) "true" else "false" },
            });
            return sfc.ssh_connection; // value copy (or null if not SSH)
        }
    }
    preview_diagnostics.debug("agent-ssh-conn", &.{
        .{ .key = "stage", .value = "no-match" },
        // "0" here means the worker thread sees an empty thread-local tab list.
        .{ .key = "tabs", .value = if (tab.g_tab_count == 0) "0" else "n" },
    });
    return null;
}
