//! WispTerm Remote layout publishing and remote AI control callbacks.

const std = @import("std");
const ghostty_vt = @import("ghostty-vt");
const Surface = @import("../Surface.zig");
const SplitTree = @import("../split_tree.zig");
const ai_chat = @import("../ai_chat.zig");
const ai_history_session = @import("../ai_history_session.zig");
const appwindow_state = @import("state.zig");
const active_tab_state = @import("active_tab.zig");
const remote = @import("../remote_client.zig");
const remote_snapshot = @import("../remote_snapshot.zig");
const renderer = @import("../renderer.zig");
const surface_snapshots = @import("surface_snapshots.zig");
const tab = @import("tab.zig");
const thread_message = @import("thread_message.zig");
const window_backend = @import("../platform/window_backend.zig");

pub const AiAgentOpenStatus = remote.AiAgentOpenStatus;

pub const Host = struct {
    client: ?*remote.Client,
    window: ?*window_backend.Window,
    state: *appwindow_state.State,
    allocator: ?std.mem.Allocator = null,
    markUiDirty: *const fn () void,
    openDefaultAiAgentForRemote: *const fn () remote.AiAgentOpenStatus,
};

pub const RemoteAiInputRequest = struct {
    tab_index: usize,
    data: []u8,
};

pub const RemoteAiAgentOpenRequest = struct {
    request_id: []const u8,
};

pub fn syncLayout(host: Host, allocator: std.mem.Allocator) void {
    const client = host.client orelse return;

    const now = std.time.milliTimestamp();
    if (!host.state.remote.shouldSendLayout(now, 250)) return;

    const layout = buildLayoutJson(host, allocator) catch return;
    defer allocator.free(layout);
    client.sendLayout(layout);
}

pub fn buildLayoutJson(host: Host, allocator: std.mem.Allocator) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try appendLayoutJson(host, allocator, &out);
    return out.toOwnedSlice(allocator);
}

fn appendLayoutJson(host: Host, allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
    try out.appendSlice(allocator, "{\"type\":\"layout\",\"activeTab\":");
    try out.print(allocator, "{d}", .{active_tab_state.g_active_tab});
    try out.appendSlice(allocator, ",\"tabs\":[");

    var wrote_tab = false;
    for (0..tab.g_tab_count) |tab_index| {
        const tab_state = tab.g_tabs[tab_index] orelse continue;
        if (wrote_tab) try out.append(allocator, ',');
        wrote_tab = true;

        if (tab_state.kind == .ai_chat) {
            try appendRemoteAiChatTabJson(host, allocator, out, tab_state, tab_index);
            continue;
        }
        if (tab_state.kind == .ai_history) {
            try appendRemoteAiHistoryTabJson(allocator, out, tab_state, tab_index);
            continue;
        }

        try out.appendSlice(allocator, "{\"index\":");
        try out.print(allocator, "{d}", .{tab_index});
        try out.appendSlice(allocator, ",\"title\":\"");
        try remote.appendJsonString(out, allocator, tab_state.getTitle());
        try out.appendSlice(allocator, "\",\"focusedSurfaceId\":\"");
        var focused_surface: ?*Surface = null;
        if (tab_state.focusedSurface()) |focused| {
            focused_surface = focused;
            try remote.appendJsonString(out, allocator, focused.remote_id[0..]);
        }
        try out.append(allocator, '"');
        try surface_snapshots.appendAgentDetectionJson(allocator, out, focused_surface);
        try out.appendSlice(allocator, ",\"surfaces\":[");

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
            var cursor_x: usize = 0;
            var cursor_y: usize = 0;
            {
                entry.surface.render_state.mutex.lock();
                defer entry.surface.render_state.mutex.unlock();
                cursor_x = entry.surface.terminal.screens.active.cursor.x;
                cursor_y = entry.surface.terminal.screens.active.cursor.y;
            }
            try out.appendSlice(allocator, ",\"cursorX\":");
            try out.print(allocator, "{d}", .{cursor_x});
            try out.appendSlice(allocator, ",\"cursorY\":");
            try out.print(allocator, "{d}", .{cursor_y});
            try out.appendSlice(allocator, ",\"snapshot\":\"");
            const snapshot = surface_snapshots.buildRemoteSurfaceSnapshot(allocator, entry.surface, remote_snapshot.default_max_history_rows) catch null;
            defer if (snapshot) |text| allocator.free(text);
            if (snapshot) |text| try remote.appendJsonString(out, allocator, text);
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

pub fn remoteAiSurfaceId(tab_index: usize) [16]u8 {
    var id: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&id, "aichat{d:0>10}", .{tab_index}) catch unreachable;
    return id;
}

pub fn remoteAiHistorySurfaceId(tab_index: usize) [16]u8 {
    var id: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&id, "aihist{d:0>10}", .{tab_index}) catch unreachable;
    return id;
}

fn registerRemoteAiInputSink(host: Host, tab_index: usize) void {
    const client = host.client orelse return;
    const window = host.window orelse return;

    const sink = host.state.remote.recordAiSink(tab_index, window_backend.nativeHandleBits(window)) orelse return;
    client.registerSurface(remoteAiSurfaceId(tab_index), sink, writeAiInput);
}

pub fn writeAiInput(ctx: *anyopaque, data: []const u8) void {
    const sink: *appwindow_state.RemoteAiInputSink = @ptrCast(@alignCast(ctx));
    const native_handle = window_backend.nativeHandleFromBits(sink.native_handle_bits) orelse return;
    const request = std.heap.page_allocator.create(RemoteAiInputRequest) catch return;
    request.* = .{
        .tab_index = sink.tab_index,
        .data = std.heap.page_allocator.dupe(u8, data) catch {
            std.heap.page_allocator.destroy(request);
            return;
        },
    };

    const ok = thread_message.postPointer(native_handle, .remote_ai_input, @intFromPtr(request));
    if (!ok) {
        std.heap.page_allocator.free(request.data);
        std.heap.page_allocator.destroy(request);
    }
}

fn appendRemoteAiChatTabJson(
    host: Host,
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    tab_state: *tab.TabState,
    tab_index: usize,
) !void {
    registerRemoteAiInputSink(host, tab_index);
    const surface_id = remoteAiSurfaceId(tab_index);
    const title_text = tab_state.getTitle();

    try out.appendSlice(allocator, "{\"index\":");
    try out.print(allocator, "{d}", .{tab_index});
    try out.appendSlice(allocator, ",\"title\":\"");
    try remote.appendJsonString(out, allocator, title_text);
    try out.appendSlice(allocator, "\",\"focusedSurfaceId\":\"");
    try remote.appendJsonString(out, allocator, surface_id[0..]);
    try out.append(allocator, '"');
    try surface_snapshots.appendAgentDetectionJson(allocator, out, null);
    try out.appendSlice(allocator, ",\"surfaces\":[{\"id\":\"");
    try remote.appendJsonString(out, allocator, surface_id[0..]);
    try out.appendSlice(allocator, "\",\"title\":\"");
    try remote.appendJsonString(out, allocator, title_text);
    try out.appendSlice(allocator, "\",\"focused\":true");
    try surface_snapshots.appendAgentDetectionJson(allocator, out, null);
    try out.appendSlice(allocator, ",\"kind\":\"ai_chat\",\"readOnly\":false,\"cols\":120,\"rows\":30,\"cursorX\":0,\"cursorY\":0,\"snapshot\":\"");
    var request_state: ai_chat.Session.RequestState = .{ .inflight = false, .stopping = false };
    if (tab_state.ai_chat_session) |session| {
        request_state = session.requestState();
        const snapshot = session.allocRemoteSnapshot(allocator) catch null;
        defer if (snapshot) |text| allocator.free(text);
        if (snapshot) |text| try remote.appendJsonString(out, allocator, text);
    }
    try out.appendSlice(allocator, "\",\"requestInflight\":");
    try out.appendSlice(allocator, if (request_state.inflight) "true" else "false");
    try out.appendSlice(allocator, ",\"requestStopping\":");
    try out.appendSlice(allocator, if (request_state.stopping) "true" else "false");
    try out.appendSlice(allocator, ",\"x\":0,\"y\":0,\"w\":1,\"h\":1}]}");
}

fn appendRemoteAiHistoryTabJson(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    tab_state: *tab.TabState,
    tab_index: usize,
) !void {
    const surface_id = remoteAiHistorySurfaceId(tab_index);
    const title_text = tab_state.getTitle();

    try out.appendSlice(allocator, "{\"index\":");
    try out.print(allocator, "{d}", .{tab_index});
    try out.appendSlice(allocator, ",\"title\":\"");
    try remote.appendJsonString(out, allocator, title_text);
    try out.appendSlice(allocator, "\",\"focusedSurfaceId\":\"");
    try remote.appendJsonString(out, allocator, surface_id[0..]);
    try out.append(allocator, '"');
    try surface_snapshots.appendAgentDetectionJson(allocator, out, null);
    try out.appendSlice(allocator, ",\"surfaces\":[{\"id\":\"");
    try remote.appendJsonString(out, allocator, surface_id[0..]);
    try out.appendSlice(allocator, "\",\"title\":\"");
    try remote.appendJsonString(out, allocator, title_text);
    try out.appendSlice(allocator, "\",\"focused\":true");
    try surface_snapshots.appendAgentDetectionJson(allocator, out, null);
    // AI History is read-only in remote layouts. Keep it terminal-style so the
    // remote client does not show AI Chat composer/input affordances.
    try out.appendSlice(allocator, ",\"kind\":\"terminal\",\"readOnly\":true,\"cols\":120,\"rows\":30,\"cursorX\":0,\"cursorY\":0,\"snapshot\":\"Sessions\\n");
    try remote.appendJsonString(out, allocator, title_text);
    try out.appendSlice(allocator, "\",\"x\":0,\"y\":0,\"w\":1,\"h\":1}]}");
}

pub fn handleAiInputRequest(request: *RemoteAiInputRequest, host: Host) void {
    defer {
        std.heap.page_allocator.free(request.data);
        std.heap.page_allocator.destroy(request);
    }
    if (request.tab_index >= tab.g_tab_count) return;
    const tab_state = tab.g_tabs[request.tab_index] orelse return;
    if (tab_state.kind != .ai_chat) return;
    const session = tab_state.ai_chat_session orelse return;
    session.applyRemoteInput(request.data);
    host.markUiDirty();
}

pub fn handleAiAgentOpenRequest(request: *RemoteAiAgentOpenRequest, host: Host) void {
    const client = host.client orelse return;

    const status = host.openDefaultAiAgentForRemote();
    client.sendAiAgentOpenResult(request.request_id, status);

    if (status == .opened) {
        host.state.remote.forceNextLayout();
        if (host.allocator) |alloc| syncLayout(host, alloc);
    }
}

fn noopMarkUiDirty() void {}

fn failOpenDefaultAiAgentForRemote() remote.AiAgentOpenStatus {
    return .failed;
}

fn testHost(state: *appwindow_state.State, allocator: std.mem.Allocator) Host {
    return .{
        .client = null,
        .window = null,
        .state = state,
        .allocator = allocator,
        .markUiDirty = noopMarkUiDirty,
        .openDefaultAiAgentForRemote = failOpenDefaultAiAgentForRemote,
    };
}

fn resetTestTabs() void {
    for (0..tab.MAX_TABS) |idx| tab.g_tabs[idx] = null;
    tab.g_tab_count = 0;
    active_tab_state.g_active_tab = 0;
}

test "remote sync: layout serializes ai_history as non-terminal surface" {
    const allocator = std.testing.allocator;
    resetTestTabs();
    defer resetTestTabs();
    var state = appwindow_state.State{};

    var session = ai_history_session.Session.init(allocator, .{
        .id = "local-history",
        .name = "Local History",
        .target = .local,
    });
    defer session.deinit();
    var tab_state = tab.TabState{
        .kind = .ai_history,
        .tree = .empty,
        .focused = .root,
        .ai_chat_session = null,
        .ai_history_session = &session,
        .copilot_session = null,
    };
    tab.g_tabs[0] = &tab_state;
    tab.g_tab_count = 1;

    const json = try buildLayoutJson(testHost(&state, allocator), allocator);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"terminal\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"ai_chat\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"readOnly\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"surfaces\":[]") == null);
}

test "remote sync: build layout json includes agent metadata from terminal snapshots" {
    const allocator = std.testing.allocator;
    resetTestTabs();
    defer resetTestTabs();
    var state = appwindow_state.State{};

    var surface: Surface = undefined;
    surface.terminal = try ghostty_vt.Terminal.init(allocator, .{
        .cols = 12,
        .rows = 4,
        .max_scrollback = 16,
        .default_modes = .{ .grapheme_cluster = true },
    });
    defer surface.terminal.deinit(allocator);
    surface.render_state = renderer.State.init(&surface.terminal);
    surface.size = .{};
    surface.size.grid.cols = 12;
    surface.size.grid.rows = 4;
    surface.ref_count = 1;
    surface.title_override_len = 0;
    surface.osc7_title_len = 0;
    surface.window_title_len = 0;
    surface.agent_detection = .{
        .app = .codex,
        .state = .waiting_approval,
        .confidence = 88,
    };
    @memcpy(surface.remote_id[0..], "term000000000001");

    var tab_state = tab.TabState{
        .kind = .terminal,
        .tree = try SplitTree.init(allocator, &surface),
        .focused = .root,
        .ai_chat_session = null,
        .ai_history_session = null,
        .copilot_session = null,
    };
    defer tab_state.tree.deinit();
    tab.g_tabs[0] = &tab_state;
    tab.g_tab_count = 1;

    const json = try buildLayoutJson(testHost(&state, allocator), allocator);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"agentApp\":\"codex\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"agentState\":\"waiting_approval\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"agentBadge\":\"ask\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"agentConfidence\":88") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"id\":\"term000000000001\"") != null);
}
