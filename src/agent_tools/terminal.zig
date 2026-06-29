//! Agent terminal context and surface-selection tools.
const std = @import("std");
const types = @import("../assistant/conversation/types.zig");
const tool_output = @import("output.zig");

const ToolContext = types.ToolContext;
const ToolSurface = types.ToolSurface;
const ToolSnapshot = types.ToolSnapshot;
const ToolClosedTab = types.ToolClosedTab;

/// Number of output lines included in a copilot context block.
pub const COPILOT_CONTEXT_LINES: usize = 40;

pub fn surfaceKind(surface: ToolSurface) []const u8 {
    if (surface.is_ssh) return "ssh";
    if (surface.is_wsl) return "wsl";
    return "terminal";
}

pub fn context(ctx: *const ToolContext) ![]u8 {
    const selected = selectedWriteContext(ctx) orelse return ctx.allocator.dupe(u8, "No terminal context is selected.");
    const snapshot_value = collectToolSnapshot(ctx) catch {
        return std.fmt.allocPrint(ctx.allocator, "Selected terminal context surface_id={s}; terminal snapshot host unavailable.", .{selected});
    };
    defer snapshot_value.deinit(ctx.allocator);
    const surface = findSurface(snapshot_value, selected) orelse {
        return std.fmt.allocPrint(ctx.allocator, "Selected terminal context surface_id={s} is no longer open.", .{selected});
    };
    if (surface.agent_app != .none) {
        return std.fmt.allocPrint(
            ctx.allocator,
            "selected surface_id={s} tab={d} focused={} kind={s} title=\"{s}\" cwd=\"{s}\" agent={s}:{s} confidence={d}",
            .{
                surface.id,
                surface.tab_index + 1,
                surface.focused,
                surfaceKind(surface),
                surface.title,
                surface.cwd,
                surface.agent_app.label(),
                surface.agent_state.label(),
                surface.agent_confidence,
            },
        );
    }
    return std.fmt.allocPrint(
        ctx.allocator,
        "selected surface_id={s} tab={d} focused={} kind={s} title=\"{s}\" cwd=\"{s}\"",
        .{
            surface.id,
            surface.tab_index + 1,
            surface.focused,
            surfaceKind(surface),
            surface.title,
            surface.cwd,
        },
    );
}

pub fn list(ctx: *const ToolContext) ![]u8 {
    const snapshot_value = collectToolSnapshot(ctx) catch return ctx.allocator.dupe(u8, "No terminal snapshot host is available.");
    defer snapshot_value.deinit(ctx.allocator);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(ctx.allocator);
    const selected = selectedWriteContext(ctx);
    // tab/active_tab are shown one-based to match the tab numbers the user sees
    // in the UI (the internal tab_index is zero-based).
    try out.print(ctx.allocator, "active_tab={d}\n", .{snapshot_value.active_tab + 1});
    if (selected) |id| {
        try out.print(ctx.allocator, "selected_context={s}\n", .{id});
    } else {
        try out.appendSlice(ctx.allocator, "selected_context=none\n");
    }
    for (snapshot_value.surfaces) |surface| {
        const is_selected = if (selected) |id| std.mem.eql(u8, id, surface.id) else false;
        try out.print(ctx.allocator, "- id={s} tab={d} focused={} selected={} kind={s} title=\"{s}\" cwd=\"{s}\"", .{
            surface.id,
            surface.tab_index + 1,
            surface.focused,
            is_selected,
            surfaceKind(surface),
            surface.title,
            surface.cwd,
        });
        if (surface.agent_app != .none) {
            try out.print(ctx.allocator, " agent={s}:{s} confidence={d}", .{
                surface.agent_app.label(),
                surface.agent_state.label(),
                surface.agent_confidence,
            });
        }
        try out.append(ctx.allocator, '\n');
    }
    return tool_output.truncateOwned(ctx.allocator, ctx.settings, try out.toOwnedSlice(ctx.allocator));
}

pub fn snapshot(ctx: *const ToolContext, surface_id: ?[]const u8) ![]u8 {
    const snapshot_value = collectToolSnapshot(ctx) catch return ctx.allocator.dupe(u8, "No terminal snapshot host is available.");
    defer snapshot_value.deinit(ctx.allocator);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(ctx.allocator);

    // Resolve a focused-surface alias (focused/active/current/empty) to a
    // concrete id so the filter below matches the focused terminal.
    var target_id = surface_id;
    if (surface_id) |sid| {
        if (resolveSurfaceId(snapshot_value, sid, selectedWriteContext(ctx))) |s| target_id = s.id;
    }

    for (snapshot_value.surfaces) |surface| {
        if (target_id) |id| {
            if (!std.mem.eql(u8, surface.id, id)) continue;
        }
        try out.print(ctx.allocator, "surface={s} title=\"{s}\" kind={s} focused={}", .{
            surface.id,
            surface.title,
            surfaceKind(surface),
            surface.focused,
        });
        if (surface.agent_app != .none) {
            try out.print(ctx.allocator, " agent={s}:{s} confidence={d}", .{
                surface.agent_app.label(),
                surface.agent_state.label(),
                surface.agent_confidence,
            });
        }
        try out.append(ctx.allocator, '\n');

        // For a specifically targeted surface, read the LIVE screen via the
        // per-surface snapshot (mutex-protected, works on the worker thread)
        // rather than the request-start pre-capture, which goes stale mid-turn.
        var live: ?[]u8 = null;
        defer if (live) |t| ctx.allocator.free(t);
        if (target_id != null) {
            if (ctx.tool_host) |host| {
                live = host.surfaceSnapshot(host.ctx, ctx.allocator, surface.id, surface.ptr) catch null;
            }
        }
        try out.appendSlice(ctx.allocator, live orelse surface.snapshot);
        try out.appendSlice(ctx.allocator, "\n---\n");
    }
    if (out.items.len == 0) {
        if (surface_id) |sid| return allocNoSurfaceError(ctx.allocator, snapshot_value, sid);
        try out.appendSlice(ctx.allocator, "No matching terminal surface.");
    }
    return tool_output.truncateTailOwned(ctx.allocator, ctx.settings, try out.toOwnedSlice(ctx.allocator));
}

pub fn select(ctx: *ToolContext, surface_id: []const u8) ![]u8 {
    const snapshot_value = collectToolSnapshot(ctx) catch return ctx.allocator.dupe(u8, "No terminal snapshot host is available.");
    defer snapshot_value.deinit(ctx.allocator);
    const surface = resolveSurfaceId(snapshot_value, surface_id, selectedWriteContext(ctx)) orelse return allocNoSurfaceError(ctx.allocator, snapshot_value, surface_id);
    setWriteContext(ctx, surface.id);
    return std.fmt.allocPrint(
        ctx.allocator,
        "selected surface_id={s} tab={d} focused={} kind={s} title=\"{s}\" cwd=\"{s}\"",
        .{
            surface.id,
            surface.tab_index + 1,
            surface.focused,
            surfaceKind(surface),
            surface.title,
            surface.cwd,
        },
    );
}

pub fn focus(ctx: *ToolContext, surface_id: []const u8) ![]u8 {
    const host = ctx.tool_host orelse return ctx.allocator.dupe(u8, "No terminal focus host is available.");
    const callback = host.focusTerminal orelse return ctx.allocator.dupe(u8, "No terminal focus host is available.");
    const surface = callback(host.ctx, ctx.allocator, surface_id) catch |err| {
        return std.fmt.allocPrint(ctx.allocator, "terminal_focus failed: {s}", .{@errorName(err)});
    };
    defer surface.deinit(ctx.allocator);
    if (ctx.tool_snapshot) |*snapshot_value| {
        snapshot_value.active_tab = surface.tab_index;
        for (snapshot_value.surfaces) |*existing| {
            existing.focused = std.mem.eql(u8, existing.id, surface.id);
        }
    }
    return std.fmt.allocPrint(
        ctx.allocator,
        "focused surface_id={s} tab={d} focused={} kind={s} title=\"{s}\" cwd=\"{s}\"",
        .{
            surface.id,
            surface.tab_index + 1,
            surface.focused,
            surfaceKind(surface),
            surface.title,
            surface.cwd,
        },
    );
}

pub fn collectToolSnapshot(ctx: *const ToolContext) !ToolSnapshot {
    if (ctx.tool_snapshot) |snapshot_value| {
        return snapshot_value.clone(ctx.allocator);
    }
    const host = ctx.tool_host orelse return error.NoTerminalSnapshotHost;
    return host.collectSnapshot(host.ctx, ctx.allocator);
}

pub fn rememberConnectedSurface(ctx: *ToolContext, surface: ToolSurface) !void {
    setWriteContext(ctx, surface.id);
    if (ctx.tool_snapshot) |*snapshot_value| {
        for (snapshot_value.surfaces) |*existing| {
            existing.focused = false;
        }
        const prev_len = snapshot_value.surfaces.len;
        snapshot_value.surfaces = try ctx.allocator.realloc(snapshot_value.surfaces, prev_len + 1);
        snapshot_value.surfaces[prev_len] = surface;
        snapshot_value.active_tab = surface.tab_index;
        return;
    }

    const surfaces = try ctx.allocator.alloc(ToolSurface, 1);
    surfaces[0] = surface;
    ctx.tool_snapshot = .{
        .surfaces = surfaces,
        .active_tab = surface.tab_index,
    };
}

pub fn rememberClosedTab(ctx: *ToolContext, closed: ToolClosedTab) !void {
    if (ctx.tool_snapshot) |*snapshot_value| {
        var write: usize = 0;
        const closed_active = snapshot_value.active_tab == closed.tab_index;
        for (snapshot_value.surfaces) |*surface| {
            if (surface.tab_index == closed.tab_index) {
                surface.deinit(ctx.allocator);
                continue;
            }
            if (surface.tab_index > closed.tab_index) {
                surface.tab_index -= 1;
            }
            snapshot_value.surfaces[write] = surface.*;
            write += 1;
        }

        snapshot_value.surfaces = try ctx.allocator.realloc(snapshot_value.surfaces, write);
        snapshot_value.active_tab = closed.active_tab;

        if (closed_active) {
            var focused_set = false;
            for (snapshot_value.surfaces) |*surface| {
                if (surface.tab_index == snapshot_value.active_tab and !focused_set) {
                    surface.focused = true;
                    focused_set = true;
                } else {
                    surface.focused = false;
                }
            }
        } else {
            for (snapshot_value.surfaces) |*surface| {
                surface.focused = surface.focused and surface.tab_index == snapshot_value.active_tab;
            }
        }
    }
}

pub fn findSurface(snapshot_value: ToolSnapshot, surface_id: []const u8) ?ToolSurface {
    for (snapshot_value.surfaces) |surface| {
        if (std.mem.eql(u8, surface.id, surface_id)) return surface;
    }
    return null;
}

/// Sentinel surface ids that mean "the terminal the user is looking at".
fn isFocusedSurfaceAlias(surface_id: []const u8) bool {
    const t = std.mem.trim(u8, surface_id, " \t\r\n");
    return t.len == 0 or
        std.ascii.eqlIgnoreCase(t, "focused") or
        std.ascii.eqlIgnoreCase(t, "active") or
        std.ascii.eqlIgnoreCase(t, "current");
}

fn focusedSurface(snapshot_value: ToolSnapshot) ?ToolSurface {
    for (snapshot_value.surfaces) |surface| {
        if (surface.focused) return surface;
    }
    return null;
}

/// Resolve a tool surface_id, honoring focused-surface aliases. A selected
/// write-context wins over UI focus so scheduled Copilot work stays attached to
/// the terminal that created it; otherwise aliases resolve to the focused
/// terminal. Returns null if nothing matches.
pub fn resolveSurfaceId(snapshot_value: ToolSnapshot, surface_id: []const u8, write_context: ?[]const u8) ?ToolSurface {
    if (isFocusedSurfaceAlias(surface_id)) {
        if (write_context) |wc| {
            if (findSurface(snapshot_value, wc)) |surface| return surface;
        }
        if (focusedSurface(snapshot_value)) |surface| return surface;
        return null;
    }
    return findSurface(snapshot_value, surface_id);
}

/// Error result for an unmatched surface_id that lists the open surfaces, so the
/// model can retry in one step instead of calling terminal_list.
pub fn allocNoSurfaceError(allocator: std.mem.Allocator, snapshot_value: ToolSnapshot, surface_id: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.print(allocator, "No terminal surface matches surface_id={s}. Open surfaces:\n", .{surface_id});
    if (snapshot_value.surfaces.len == 0) try out.appendSlice(allocator, "(none)\n");
    for (snapshot_value.surfaces) |surface| {
        try out.print(allocator, "- id={s} tab={d} focused={} kind={s} title=\"{s}\"\n", .{
            surface.id,
            surface.tab_index + 1,
            surface.focused,
            surfaceKind(surface),
            surface.title,
        });
    }
    try out.appendSlice(allocator, "Use one of these ids, or surface_id=focused for the focused terminal.");
    return out.toOwnedSlice(allocator);
}

/// Build the per-message copilot context block from a full surface snapshot:
/// the cwd plus the last COPILOT_CONTEXT_LINES lines of output. Owned result.
pub fn buildCopilotContext(allocator: std.mem.Allocator, cwd: []const u8, surface_snapshot: []const u8) ![]u8 {
    const trimmed = std.mem.trimRight(u8, surface_snapshot, "\n");
    var start: usize = trimmed.len;
    var newlines: usize = 0;
    while (start > 0) {
        const c = trimmed[start - 1];
        if (c == '\n') {
            newlines += 1;
            if (newlines > COPILOT_CONTEXT_LINES) break;
        }
        start -= 1;
    }
    const tail = trimmed[start..];
    return std.fmt.allocPrint(
        allocator,
        "[wispterm current terminal]\ncwd: {s}\nrecent output:\n{s}",
        .{ cwd, tail },
    );
}

pub fn selectedWriteContext(ctx: *const ToolContext) ?[]const u8 {
    return ctx.writeContextSurfaceId();
}

pub fn setWriteContext(ctx: *ToolContext, surface_id: []const u8) void {
    const len = @min(surface_id.len, ctx.write_context_surface_id.len);
    @memcpy(ctx.write_context_surface_id[0..len], surface_id[0..len]);
    ctx.write_context_surface_id_len = len;
}

/// Copilot fallback: when an exec tool omits surface_id, use the context's
/// pre-seeded write-context (the bound/focused terminal). Non-copilot requests
/// keep the original "Missing surface_id" behavior.
pub fn defaultExecSurfaceId(ctx: *const ToolContext) ?[]const u8 {
    if (!ctx.copilot) return null;
    return ctx.writeContextSurfaceId();
}

pub fn ensureWriteContext(ctx: *ToolContext, surface: ToolSurface) !?[]u8 {
    const write_context = selectedWriteContext(ctx) orelse {
        const message = try std.fmt.allocPrint(
            ctx.allocator,
            "Refusing to write to surface_id={s} tab={d} title=\"{s}\" because no agent terminal context is selected. Call terminal_select with the intended surface_id before writing.",
            .{ surface.id, surface.tab_index + 1, surface.title },
        );
        return message;
    };
    if (std.mem.eql(u8, write_context, surface.id)) return null;

    const message = try std.fmt.allocPrint(
        ctx.allocator,
        "Refusing to write to surface_id={s} tab={d} title=\"{s}\" because selected agent terminal context is surface_id={s}. Call terminal_select with the intended surface_id before writing to another panel.",
        .{
            surface.id,
            surface.tab_index + 1,
            surface.title,
            write_context,
        },
    );
    return message;
}

test "buildCopilotContext keeps cwd and the last N lines" {
    const snap = "l1\nl2\nl3\nl4\nl5\n";
    const out = try buildCopilotContext(std.testing.allocator, "/home/u", snap);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "cwd: /home/u") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "l5") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "l1") != null);
}

test "buildCopilotContext truncates to the last COPILOT_CONTEXT_LINES" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    var i: usize = 0;
    while (i < 100) : (i += 1) try buf.print(std.testing.allocator, "line{d}\n", .{i});
    const out = try buildCopilotContext(std.testing.allocator, "/x", buf.items);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "line99") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "line0\n") == null);
}

fn fakeApprove(_: *anyopaque, _: []const u8, _: []const u8, _: []const u8) bool {
    return true;
}

fn fakeCancelled(_: *anyopaque) bool {
    return false;
}

const LiveSnapshotHost = struct {
    settled_text: []const u8,
    snap_calls: usize = 0,

    fn collectSnapshot(_: *anyopaque, _: std.mem.Allocator) anyerror!ToolSnapshot {
        return error.Unsupported;
    }

    fn surfaceSnapshot(ctx_ptr: *anyopaque, allocator: std.mem.Allocator, _: []const u8, _: *anyopaque) anyerror![]u8 {
        const self: *LiveSnapshotHost = @ptrCast(@alignCast(ctx_ptr));
        self.snap_calls += 1;
        return allocator.dupe(u8, self.settled_text);
    }

    fn writeSurface(_: *anyopaque, _: []const u8, _: *anyopaque, _: []const u8) bool {
        return false;
    }

    fn spawnTab(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: ?[]const u8) anyerror!ToolSurface {
        return error.Unsupported;
    }

    fn closeTab(_: *anyopaque, _: std.mem.Allocator, _: ?usize, _: ?[]const u8, _: ?[]const u8) anyerror!ToolClosedTab {
        return error.Unsupported;
    }

    fn saveSshProfile(_: *anyopaque, _: std.mem.Allocator, _: types.SshProfileSaveArgs) anyerror!types.SavedSshProfile {
        return error.Unsupported;
    }

    fn connectSshProfile(_: *anyopaque, _: std.mem.Allocator, _: []const u8) anyerror!ToolSurface {
        return error.Unsupported;
    }

    fn host(self: *LiveSnapshotHost) types.ToolHost {
        return .{
            .ctx = self,
            .collectSnapshot = collectSnapshot,
            .surfaceSnapshot = surfaceSnapshot,
            .writeSurface = writeSurface,
            .spawnTab = spawnTab,
            .closeTab = closeTab,
            .saveSshProfile = saveSshProfile,
            .connectSshProfile = connectSshProfile,
        };
    }
};

fn twoSurfaceSnapshotForTest(allocator: std.mem.Allocator) !ToolSnapshot {
    var surfaces = try allocator.alloc(ToolSurface, 2);
    surfaces[0] = .{
        .id = try allocator.dupe(u8, "aaa"),
        .title = try allocator.dupe(u8, "shell"),
        .cwd = try allocator.dupe(u8, "/"),
        .snapshot = try allocator.dupe(u8, "$ "),
        .tab_index = 0,
        .focused = false,
        .is_ssh = false,
        .is_wsl = false,
        .agent_app = .none,
        .agent_state = .none,
        .agent_confidence = 0,
        .ptr = @ptrFromInt(1),
    };
    surfaces[1] = .{
        .id = try allocator.dupe(u8, "bbb"),
        .title = try allocator.dupe(u8, "codex"),
        .cwd = try allocator.dupe(u8, "/"),
        .snapshot = try allocator.dupe(u8, "› "),
        .tab_index = 0,
        .focused = true,
        .is_ssh = false,
        .is_wsl = false,
        .agent_app = .codex,
        .agent_state = .none,
        .agent_confidence = 50,
        .ptr = @ptrFromInt(2),
    };
    return .{ .surfaces = surfaces, .active_tab = 0 };
}

test "collectToolSnapshot prefers request-local terminal snapshot" {
    const allocator = std.testing.allocator;
    var surfaces = try allocator.alloc(ToolSurface, 1);
    surfaces[0] = .{
        .id = try allocator.dupe(u8, "surface-1"),
        .title = try allocator.dupe(u8, "Local Shell"),
        .cwd = try allocator.dupe(u8, "/home/user"),
        .snapshot = try allocator.dupe(u8, "$ "),
        .tab_index = 1,
        .focused = true,
        .is_ssh = false,
        .is_wsl = false,
        .agent_app = .none,
        .agent_state = .none,
        .agent_confidence = 0,
        .ptr = @ptrFromInt(1),
    };
    const cached_snapshot = ToolSnapshot{
        .surfaces = surfaces,
        .active_tab = 1,
    };
    defer cached_snapshot.deinit(allocator);

    var dummy: u8 = 0;
    const ctx = ToolContext{
        .allocator = allocator,
        .ctx = &dummy,
        .tool_host = null,
        .tool_snapshot = cached_snapshot,
        .settings = .{},
        .approve = fakeApprove,
        .cancelled = fakeCancelled,
    };

    const snapshot_value = try collectToolSnapshot(&ctx);
    defer snapshot_value.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), snapshot_value.active_tab);
    try std.testing.expectEqual(@as(usize, 1), snapshot_value.surfaces.len);
    try std.testing.expectEqualStrings("surface-1", snapshot_value.surfaces[0].id);
    try std.testing.expect(snapshot_value.surfaces[0].id.ptr != cached_snapshot.surfaces[0].id.ptr);
}

test "snapshot reads the live surface screen for a targeted surface" {
    const allocator = std.testing.allocator;
    var host_ctx = LiveSnapshotHost{ .settled_text = "LIVE-SCREEN-9999" };
    var surfaces = try allocator.alloc(ToolSurface, 1);
    surfaces[0] = .{
        .id = try allocator.dupe(u8, "s1"),
        .title = try allocator.dupe(u8, "Local Shell"),
        .cwd = try allocator.dupe(u8, "/home/user"),
        // The request-start pre-capture is stale; the live read must win.
        .snapshot = try allocator.dupe(u8, "STALE-PRECAPTURE-0000"),
        .tab_index = 0,
        .focused = true,
        .is_ssh = false,
        .is_wsl = false,
        .agent_app = .none,
        .agent_state = .none,
        .agent_confidence = 0,
        .ptr = @ptrFromInt(1),
    };
    const cached = ToolSnapshot{ .surfaces = surfaces, .active_tab = 0 };
    defer cached.deinit(allocator);

    var dummy: u8 = 0;
    const ctx = ToolContext{
        .allocator = allocator,
        .ctx = &dummy,
        .tool_host = LiveSnapshotHost.host(&host_ctx),
        .tool_snapshot = cached,
        .settings = .{},
        .approve = fakeApprove,
        .cancelled = fakeCancelled,
    };

    const result = try snapshot(&ctx, "s1");
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "LIVE-SCREEN-9999") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "STALE-PRECAPTURE") == null);
    try std.testing.expectEqual(@as(usize, 1), host_ctx.snap_calls);
}

test "write context requires explicit selection and can switch surfaces" {
    const allocator = std.testing.allocator;
    var surfaces = try allocator.alloc(ToolSurface, 2);
    surfaces[0] = .{
        .id = try allocator.dupe(u8, "surface-a"),
        .title = try allocator.dupe(u8, "panel1"),
        .cwd = try allocator.dupe(u8, ""),
        .snapshot = try allocator.dupe(u8, ""),
        .tab_index = 0,
        .focused = false,
        .is_ssh = false,
        .is_wsl = false,
        .agent_app = .none,
        .agent_state = .none,
        .agent_confidence = 0,
        .ptr = @ptrFromInt(1),
    };
    surfaces[1] = .{
        .id = try allocator.dupe(u8, "surface-b"),
        .title = try allocator.dupe(u8, "panel2"),
        .cwd = try allocator.dupe(u8, ""),
        .snapshot = try allocator.dupe(u8, ""),
        .tab_index = 0,
        .focused = false,
        .is_ssh = false,
        .is_wsl = false,
        .agent_app = .none,
        .agent_state = .none,
        .agent_confidence = 0,
        .ptr = @ptrFromInt(2),
    };
    const snapshot_value = ToolSnapshot{
        .surfaces = surfaces,
        .active_tab = 0,
    };
    defer snapshot_value.deinit(allocator);

    var dummy: u8 = 0;
    var ctx = ToolContext{
        .allocator = allocator,
        .ctx = &dummy,
        .tool_host = null,
        .tool_snapshot = null,
        .settings = .{},
        .approve = fakeApprove,
        .cancelled = fakeCancelled,
    };

    const missing = (try ensureWriteContext(&ctx, snapshot_value.surfaces[1])).?;
    defer allocator.free(missing);
    try std.testing.expect(std.mem.indexOf(u8, missing, "no agent terminal context is selected") != null);

    setWriteContext(&ctx, snapshot_value.surfaces[1].id);
    try std.testing.expectEqualStrings("surface-b", ctx.write_context_surface_id[0..ctx.write_context_surface_id_len]);
    try std.testing.expect(try ensureWriteContext(&ctx, snapshot_value.surfaces[1]) == null);

    const message = (try ensureWriteContext(&ctx, snapshot_value.surfaces[0])).?;
    defer allocator.free(message);
    try std.testing.expect(std.mem.indexOf(u8, message, "selected agent terminal context is surface_id=surface-b") != null);

    setWriteContext(&ctx, snapshot_value.surfaces[0].id);
    try std.testing.expectEqualStrings("surface-a", ctx.write_context_surface_id[0..ctx.write_context_surface_id_len]);
    try std.testing.expect(try ensureWriteContext(&ctx, snapshot_value.surfaces[0]) == null);
    const switched = (try ensureWriteContext(&ctx, snapshot_value.surfaces[1])).?;
    defer allocator.free(switched);
    try std.testing.expect(std.mem.indexOf(u8, switched, "selected agent terminal context is surface_id=surface-a") != null);
}

test "list shows one-based tab numbers matching the UI" {
    const allocator = std.testing.allocator;
    var surfaces = try allocator.alloc(ToolSurface, 2);
    surfaces[0] = .{
        .id = try allocator.dupe(u8, "surface-a"),
        .title = try allocator.dupe(u8, "panel1"),
        .cwd = try allocator.dupe(u8, "/tmp"),
        .snapshot = try allocator.dupe(u8, ""),
        .tab_index = 0,
        .focused = true,
        .is_ssh = false,
        .is_wsl = false,
        .agent_app = .none,
        .agent_state = .none,
        .agent_confidence = 0,
        .ptr = @ptrFromInt(1),
    };
    surfaces[1] = .{
        .id = try allocator.dupe(u8, "surface-b"),
        .title = try allocator.dupe(u8, "panel2"),
        .cwd = try allocator.dupe(u8, "/tmp"),
        .snapshot = try allocator.dupe(u8, ""),
        .tab_index = 1,
        .focused = false,
        .is_ssh = false,
        .is_wsl = false,
        .agent_app = .none,
        .agent_state = .none,
        .agent_confidence = 0,
        .ptr = @ptrFromInt(2),
    };
    const snapshot_value = ToolSnapshot{ .surfaces = surfaces, .active_tab = 0 };
    defer snapshot_value.deinit(allocator);

    var dummy: u8 = 0;
    const ctx = ToolContext{
        .allocator = allocator,
        .ctx = &dummy,
        .tool_host = null,
        .tool_snapshot = snapshot_value,
        .settings = .{},
        .approve = fakeApprove,
        .cancelled = fakeCancelled,
    };

    const out = try list(&ctx);
    defer allocator.free(out);

    // The first tab is shown as 1 and the second as 2, even though they are
    // internally zero-based (tab_index 0 and 1) — matching the UI tab numbers.
    try std.testing.expect(std.mem.indexOf(u8, out, "active_tab=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "id=surface-a tab=1 ") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "id=surface-b tab=2 ") != null);
    // The zero-based index must never leak into the user-facing listing.
    try std.testing.expect(std.mem.indexOf(u8, out, "tab=0") == null);
}

test "select resolves focused aliases and reports missing surfaces" {
    const allocator = std.testing.allocator;
    const cached = try twoSurfaceSnapshotForTest(allocator);
    defer cached.deinit(allocator);
    var dummy: u8 = 0;
    var ctx = ToolContext{
        .allocator = allocator,
        .ctx = &dummy,
        .tool_host = null,
        .tool_snapshot = cached,
        .settings = .{},
        .approve = fakeApprove,
        .cancelled = fakeCancelled,
    };
    for ([_][]const u8{ "focused", "active", "current", "" }) |alias| {
        const result = try select(&ctx, alias);
        defer allocator.free(result);
        try std.testing.expect(std.mem.indexOf(u8, result, "surface_id=bbb") != null);
    }

    const exact = try select(&ctx, "aaa");
    defer allocator.free(exact);
    try std.testing.expect(std.mem.indexOf(u8, exact, "surface_id=aaa") != null);

    const missing = try select(&ctx, "zzz");
    defer allocator.free(missing);
    try std.testing.expect(std.mem.indexOf(u8, missing, "zzz") != null);
    try std.testing.expect(std.mem.indexOf(u8, missing, "aaa") != null);
    try std.testing.expect(std.mem.indexOf(u8, missing, "bbb") != null);
}

test "select focused alias honors write context before UI focus and falls back when stale" {
    const allocator = std.testing.allocator;
    const cached = try twoSurfaceSnapshotForTest(allocator);
    defer cached.deinit(allocator);
    var dummy: u8 = 0;
    var ctx = ToolContext{
        .allocator = allocator,
        .ctx = &dummy,
        .tool_host = null,
        .tool_snapshot = cached,
        .settings = .{},
        .approve = fakeApprove,
        .cancelled = fakeCancelled,
    };
    setWriteContext(&ctx, "aaa");

    const result = try select(&ctx, "focused");
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "surface_id=aaa") != null);
    try std.testing.expectEqualStrings("aaa", ctx.write_context_surface_id[0..ctx.write_context_surface_id_len]);

    setWriteContext(&ctx, "closed-surface");
    const fallback = try select(&ctx, "focused");
    defer allocator.free(fallback);
    try std.testing.expect(std.mem.indexOf(u8, fallback, "surface_id=bbb") != null);
    try std.testing.expectEqualStrings("bbb", ctx.write_context_surface_id[0..ctx.write_context_surface_id_len]);
}
