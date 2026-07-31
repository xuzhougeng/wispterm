//! Shared surface snapshot helpers for remote and agent control paths.

const std = @import("std");
const Surface = @import("../Surface.zig");
const ai_chat = @import("../assistant/conversation/session.zig");
const agent_detector = @import("../terminal_agents/detector.zig");
const preview_diagnostics = @import("../preview/diagnostics.zig");
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

/// Web-console snapshot: plain text plus the host VT's mode state so the
/// remote xterm mirrors desktop input behavior (issue #502). Text-only
/// consumers keep using buildRemoteSurfaceSnapshot.
pub fn buildRemoteSurfaceSnapshotWithModes(allocator: std.mem.Allocator, surface: *Surface, max_history_rows: usize) ![]u8 {
    surface.render_state.mutex.lock();
    defer surface.render_state.mutex.unlock();
    return remote_snapshot.allocTerminalSnapshotWithModes(
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

/// Poll a surface's child-process exit state for the ACP `terminal/*`
/// capability (`terminal/output`, `terminal/wait_for_exit`).
///
/// `.exited`/`.failed` report exited=true; `.starting`/`.running`/`.stopping`
/// report exited=false. `.stopped` also reports exited=false — in practice it
/// is unobservable here: `.stopped` is only ever set by `Surface.deinit`'s
/// teardown sequence, which first calls `surface_registry.unregister` (see
/// deinit's step 0), and `unregister` blocks until any in-flight `acquire()`
/// guard — including the one this function holds — releases. So by the time
/// a caller can reach `.stopped` through this guarded path, the surface is
/// gone from the registry and `acquire` below has already failed with
/// `error.SurfaceClosed`.
pub fn agentSurfaceExitStatus(ctx: *anyopaque, surface_id: []const u8, surface_ptr: *anyopaque) anyerror!ai_chat.SurfaceExitInfo {
    _ = ctx;
    if (!surface_registry.acquire(surface_ptr, surface_id)) return error.SurfaceClosed;
    defer surface_registry.release();
    const surface: *Surface = @ptrCast(@alignCast(surface_ptr));
    return switch (surface.currentIoState()) {
        .exited => |info| .{
            .exited = true,
            .exit_code = exitCodeFromInfo(surface, info),
        },
        .failed => .{ .exited = true, .exit_code = null },
        else => .{ .exited = false, .exit_code = null },
    };
}

/// `ExitInfo.status` is normally populated at the moment of exit (see
/// `Surface.markExited` call sites, which all pass `surface.pollExitStatus()`)
/// but can race to null if the non-blocking wait() didn't yet observe the
/// child as reaped. Re-poll once in that case: it's a cheap non-blocking
/// waitpid and may catch the exit code the first poll missed.
fn exitCodeFromInfo(surface: *Surface, info: Surface.ExitInfo) ?u32 {
    if (info.status) |status| return switch (status) {
        .exited => |code| code,
        .unknown => null,
    };
    const status = surface.pollExitStatus() orelse return null;
    return switch (status) {
        .exited => |code| code,
        .unknown => null,
    };
}

/// Kill a surface's child process for the ACP `terminal/kill` capability.
/// Same worker-thread hazard as agentSurfaceSnapshot.
pub fn agentKillSurfaceChild(ctx: *anyopaque, surface_id: []const u8, surface_ptr: *anyopaque) anyerror!void {
    _ = ctx;
    if (!surface_registry.acquire(surface_ptr, surface_id)) return error.SurfaceClosed;
    defer surface_registry.release();
    const surface: *Surface = @ptrCast(@alignCast(surface_ptr));
    surface.command.kill();
}

pub fn agentWriteSurface(ctx: *anyopaque, surface_id: []const u8, surface_ptr: *anyopaque, data: []const u8) bool {
    _ = ctx;
    // Same worker-thread hazard as agentSurfaceSnapshot.
    if (!surface_registry.acquire(surface_ptr, surface_id)) return false;
    defer surface_registry.release();
    const surface: *Surface = @ptrCast(@alignCast(surface_ptr));
    surface.queuePtyWrite(data) catch |err| {
        std.log.scoped(.agent).warn(
            "dropped agent write ({d} bytes): {s}",
            .{ data.len, @errorName(err) },
        );
        return false;
    };
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
    try std.testing.expectError(error.SurfaceClosed, agentSurfaceExitStatus(ptr, "missing", ptr));
    try std.testing.expectError(error.SurfaceClosed, agentKillSurfaceChild(ptr, "missing", ptr));
}

pub fn agentSshConnectionForSurface(ctx: *anyopaque, surface_id: []const u8) ?Surface.SshConnection {
    _ = ctx;
    if (surface_id.len == 0) return null;
    const ptr = surface_registry.acquireById(surface_id) orelse {
        preview_diagnostics.debug("agent-ssh-conn", &.{.{ .key = "stage", .value = "no-match" }});
        return null;
    };
    defer surface_registry.release();
    const surface: *Surface = @ptrCast(@alignCast(ptr));
    preview_diagnostics.debug("agent-ssh-conn", &.{
        .{ .key = "stage", .value = "match" },
        .{ .key = "has_conn", .value = if (surface.ssh_connection != null) "true" else "false" },
    });
    return surface.ssh_connection; // value copy (or null if not SSH)
}

test "agent SSH connection resolver rejects unregistered surface id" {
    try std.testing.expect(agentSshConnectionForSurface(undefined, "missing") == null);
}

test "agent SSH connection resolver uses registry source" {
    const source = @embedFile("surface_snapshots.zig");
    const start = std.mem.indexOf(u8, source, "pub fn agentSshConnectionForSurface") orelse return error.MissingAgentSshResolver;
    const rest = source[start..];
    const end = std.mem.indexOf(u8, rest, "test \"agent SSH") orelse return error.MissingAgentSshResolverEnd;
    const body = rest[0..end];
    try std.testing.expect(std.mem.indexOf(u8, body, "surface_registry.acquireById") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "tab.g_") == null);
}
