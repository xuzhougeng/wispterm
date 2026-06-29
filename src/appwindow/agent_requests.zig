//! Agent tool request bridge.
//!
//! Worker-facing agent callbacks synchronously marshal tab/SSH requests onto
//! the UI thread. AppWindow supplies the actual operations through Host so this
//! module owns only the callback/request boundary.

const std = @import("std");

const Surface = @import("../Surface.zig");
const ai_chat = @import("../assistant/conversation/session.zig");
const ai_chat_types = @import("../assistant/conversation/types.zig");
const platform_pty_command = @import("../platform/pty_command.zig");
const window_backend = @import("../platform/window_backend.zig");
const active_tab_state = @import("active_tab.zig");
const surface_snapshots = @import("surface_snapshots.zig");
const tab = @import("tab.zig");
const thread_message = @import("thread_message.zig");

const ui_screenshot_timeout_ns = 30 * std.time.ns_per_s;
const ui_screenshot_request_allocator = std.heap.page_allocator;

pub const SshConnectResult = union(enum) {
    connected: *Surface,
    not_found,
    failed,
};

pub const Host = struct {
    nativeHandleForContext: *const fn (*anyopaque) ?window_backend.NativeHandle,
    currentNativeHandle: *const fn () ?window_backend.NativeHandle,
    spawnDefaultTab: *const fn () ?*Surface,
    spawnTabWithCommand: *const fn ([]const u8) ?*Surface,
    closeTabByIndex: *const fn (usize) void,
    connectSshProfile: *const fn ([]const u8) SshConnectResult,
    saveSshProfile: *const fn (std.mem.Allocator, ai_chat.SshProfileSaveArgs) anyerror!ai_chat.SavedSshProfile,
    captureUiScreenshot: *const fn (std.mem.Allocator, ai_chat_types.UiScreenshotTarget, ?[]const u8, ?[]const u8) anyerror!ai_chat_types.UiScreenshotResult,
    focusTerminalSurface: *const fn (std.mem.Allocator, []const u8) anyerror!ai_chat.ToolSurface,
};

pub const AgentSshConnectRequest = struct {
    allocator: std.mem.Allocator,
    profile_name: []const u8,
    result: ?ai_chat.ToolSurface = null,
    err: ?anyerror = null,
};

pub const AgentSshSaveRequest = struct {
    allocator: std.mem.Allocator,
    args: ai_chat.SshProfileSaveArgs,
    result: ?ai_chat.SavedSshProfile = null,
    err: ?anyerror = null,
};

pub const AgentTabNewRequest = struct {
    allocator: std.mem.Allocator,
    kind: []const u8,
    command: ?[]const u8,
    result: ?ai_chat.ToolSurface = null,
    err: ?anyerror = null,
};

pub const AgentTabCloseRequest = struct {
    allocator: std.mem.Allocator,
    tab_index: ?usize,
    surface_id: ?[]const u8,
    title: ?[]const u8,
    result: ?ai_chat.ToolClosedTab = null,
    err: ?anyerror = null,
};

pub const AgentUiScreenshotRequest = struct {
    allocator: std.mem.Allocator,
    target: ai_chat_types.UiScreenshotTarget,
    surface_id: ?[]u8,
    working_dir: ?[]u8,
    result: ?ai_chat_types.UiScreenshotResult = null,
    err: ?anyerror = null,
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    done: bool = false,
    abandoned: bool = false,
    next: ?*AgentUiScreenshotRequest = null,
};

pub const AgentTerminalFocusRequest = struct {
    allocator: std.mem.Allocator,
    surface_id: []const u8,
    result: ?ai_chat.ToolSurface = null,
    err: ?anyerror = null,
};

var g_host: ?Host = null;
threadlocal var pending_ui_screenshot_head: ?*AgentUiScreenshotRequest = null;
threadlocal var pending_ui_screenshot_tail: ?*AgentUiScreenshotRequest = null;

pub fn setHost(host: Host) void {
    g_host = host;
}

fn installedHost() anyerror!Host {
    return g_host orelse error.WindowUnavailable;
}

fn postAgentRequest(native_handle: window_backend.NativeHandle, tag: thread_message.Tag, ptr: usize) void {
    _ = thread_message.sendPointer(native_handle, tag, ptr);
}

fn postAgentTabNew(native_handle: window_backend.NativeHandle, request: *AgentTabNewRequest) void {
    postAgentRequest(native_handle, .agent_tab_new, @intFromPtr(request));
}

fn postAgentTabClose(native_handle: window_backend.NativeHandle, request: *AgentTabCloseRequest) void {
    postAgentRequest(native_handle, .agent_tab_close, @intFromPtr(request));
}

fn postAgentSshConnect(native_handle: window_backend.NativeHandle, request: *AgentSshConnectRequest) void {
    postAgentRequest(native_handle, .agent_ssh_connect, @intFromPtr(request));
}

fn postAgentSshSave(native_handle: window_backend.NativeHandle, request: *AgentSshSaveRequest) void {
    postAgentRequest(native_handle, .agent_ssh_save, @intFromPtr(request));
}

fn postAgentUiScreenshot(native_handle: window_backend.NativeHandle, request: *AgentUiScreenshotRequest) bool {
    return thread_message.postPointer(native_handle, .agent_ui_screenshot, @intFromPtr(request));
}

fn postAgentTerminalFocus(native_handle: window_backend.NativeHandle, request: *AgentTerminalFocusRequest) void {
    postAgentRequest(native_handle, .agent_terminal_focus, @intFromPtr(request));
}

fn destroyUiScreenshotRequest(request: *AgentUiScreenshotRequest) void {
    if (request.surface_id) |surface_id| ui_screenshot_request_allocator.free(surface_id);
    if (request.working_dir) |working_dir| ui_screenshot_request_allocator.free(working_dir);
    ui_screenshot_request_allocator.destroy(request);
}

fn createUiScreenshotRequest(
    target: ai_chat_types.UiScreenshotTarget,
    surface_id: ?[]const u8,
    working_dir: ?[]const u8,
) !*AgentUiScreenshotRequest {
    const request = try ui_screenshot_request_allocator.create(AgentUiScreenshotRequest);
    errdefer ui_screenshot_request_allocator.destroy(request);

    const surface_id_copy = if (surface_id) |value|
        try ui_screenshot_request_allocator.dupe(u8, value)
    else
        null;
    errdefer if (surface_id_copy) |value| ui_screenshot_request_allocator.free(value);

    const working_dir_copy = if (working_dir) |value|
        try ui_screenshot_request_allocator.dupe(u8, value)
    else
        null;
    errdefer if (working_dir_copy) |value| ui_screenshot_request_allocator.free(value);

    request.* = .{
        .allocator = ui_screenshot_request_allocator,
        .target = target,
        .surface_id = surface_id_copy,
        .working_dir = working_dir_copy,
    };
    return request;
}

fn cloneUiScreenshotResult(allocator: std.mem.Allocator, result: ai_chat_types.UiScreenshotResult) !ai_chat_types.UiScreenshotResult {
    const path = try allocator.dupe(u8, result.path);
    errdefer allocator.free(path);

    const surface_id = if (result.surface_id) |value|
        try allocator.dupe(u8, value)
    else
        null;
    errdefer if (surface_id) |value| allocator.free(value);

    return .{
        .path = path,
        .mime = result.mime,
        .width = result.width,
        .height = result.height,
        .target = result.target,
        .surface_id = surface_id,
    };
}

fn waitUiScreenshotRequest(
    request: *AgentUiScreenshotRequest,
    allocator: std.mem.Allocator,
) anyerror!ai_chat_types.UiScreenshotResult {
    request.mutex.lock();
    while (!request.done) {
        request.cond.timedWait(&request.mutex, ui_screenshot_timeout_ns) catch |err| switch (err) {
            error.Timeout => {
                if (request.done) break;
                request.abandoned = true;
                request.mutex.unlock();
                return error.WindowUnavailable;
            },
        };
    }
    const request_err = request.err;
    const request_result = request.result;
    request.mutex.unlock();
    defer destroyUiScreenshotRequest(request);

    if (request_err) |err| return err;
    var result = request_result orelse return error.ScreenshotFailed;
    defer result.deinit(ui_screenshot_request_allocator);
    return cloneUiScreenshotResult(allocator, result);
}

fn completeUiScreenshotRequest(
    request: *AgentUiScreenshotRequest,
    result: ?ai_chat_types.UiScreenshotResult,
    err: ?anyerror,
) void {
    request.mutex.lock();
    if (request.abandoned) {
        request.mutex.unlock();
        if (result) |owned_result| {
            var mutable = owned_result;
            mutable.deinit(ui_screenshot_request_allocator);
        }
        destroyUiScreenshotRequest(request);
        return;
    }
    request.result = result;
    request.err = err;
    request.done = true;
    request.cond.signal();
    request.mutex.unlock();
}

fn enqueueUiScreenshotRequest(request: *AgentUiScreenshotRequest) void {
    request.next = null;
    if (pending_ui_screenshot_tail) |tail| {
        tail.next = request;
    } else {
        pending_ui_screenshot_head = request;
    }
    pending_ui_screenshot_tail = request;
}

fn popUiScreenshotRequest() ?*AgentUiScreenshotRequest {
    const request = pending_ui_screenshot_head orelse return null;
    pending_ui_screenshot_head = request.next;
    if (pending_ui_screenshot_head == null) pending_ui_screenshot_tail = null;
    request.next = null;
    return request;
}

pub fn hasPendingUiScreenshot() bool {
    return pending_ui_screenshot_head != null;
}

pub fn failPendingUiScreenshots(err: anyerror) void {
    while (popUiScreenshotRequest()) |request| {
        completeUiScreenshotRequest(request, null, err);
    }
}

pub fn capturePendingUiScreenshots(host: Host) void {
    while (popUiScreenshotRequest()) |request| {
        const result = host.captureUiScreenshot(
            request.allocator,
            request.target,
            request.surface_id,
            request.working_dir,
        ) catch |err| {
            completeUiScreenshotRequest(request, null, err);
            continue;
        };
        completeUiScreenshotRequest(request, result, null);
    }
}

pub fn spawnTab(ctx: *anyopaque, allocator: std.mem.Allocator, kind: []const u8, command: ?[]const u8) anyerror!ai_chat.ToolSurface {
    const host = try installedHost();
    const native_handle = host.nativeHandleForContext(ctx) orelse return error.WindowUnavailable;

    var request = AgentTabNewRequest{
        .allocator = allocator,
        .kind = kind,
        .command = command,
    };

    if (host.currentNativeHandle()) |current| {
        if (current == native_handle) {
            handleTabNewRequest(&request, host);
        } else {
            postAgentTabNew(native_handle, &request);
        }
    } else {
        postAgentTabNew(native_handle, &request);
    }

    if (request.err) |err| return err;
    return request.result orelse error.SpawnFailed;
}

pub fn closeTab(ctx: *anyopaque, allocator: std.mem.Allocator, tab_index: ?usize, surface_id: ?[]const u8, title_text: ?[]const u8) anyerror!ai_chat.ToolClosedTab {
    const host = try installedHost();
    const native_handle = host.nativeHandleForContext(ctx) orelse return error.WindowUnavailable;

    var request = AgentTabCloseRequest{
        .allocator = allocator,
        .tab_index = tab_index,
        .surface_id = surface_id,
        .title = title_text,
    };

    if (host.currentNativeHandle()) |current| {
        if (current == native_handle) {
            handleTabCloseRequest(&request, host);
        } else {
            postAgentTabClose(native_handle, &request);
        }
    } else {
        postAgentTabClose(native_handle, &request);
    }

    if (request.err) |err| return err;
    return request.result orelse error.TabNotFound;
}

pub fn connectSshProfile(ctx: *anyopaque, allocator: std.mem.Allocator, profile_name: []const u8) anyerror!ai_chat.ToolSurface {
    const host = try installedHost();
    const native_handle = host.nativeHandleForContext(ctx) orelse return error.WindowUnavailable;

    var request = AgentSshConnectRequest{
        .allocator = allocator,
        .profile_name = profile_name,
    };

    if (host.currentNativeHandle()) |current| {
        if (current == native_handle) {
            handleSshConnectRequest(&request, host);
        } else {
            postAgentSshConnect(native_handle, &request);
        }
    } else {
        postAgentSshConnect(native_handle, &request);
    }

    if (request.err) |err| return err;
    return request.result orelse error.ConnectFailed;
}

pub fn saveSshProfile(ctx: *anyopaque, allocator: std.mem.Allocator, args: ai_chat.SshProfileSaveArgs) anyerror!ai_chat.SavedSshProfile {
    const host = try installedHost();
    const native_handle = host.nativeHandleForContext(ctx) orelse return error.WindowUnavailable;

    var request = AgentSshSaveRequest{
        .allocator = allocator,
        .args = args,
    };

    if (host.currentNativeHandle()) |current| {
        if (current == native_handle) {
            handleSshSaveRequest(&request, host);
        } else {
            postAgentSshSave(native_handle, &request);
        }
    } else {
        postAgentSshSave(native_handle, &request);
    }

    if (request.err) |err| return err;
    return request.result orelse error.SaveFailed;
}

pub fn uiScreenshot(
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    target: ai_chat_types.UiScreenshotTarget,
    surface_id: ?[]const u8,
    working_dir: ?[]const u8,
) anyerror!ai_chat_types.UiScreenshotResult {
    const host = try installedHost();
    const native_handle = host.nativeHandleForContext(ctx) orelse return error.WindowUnavailable;

    if (host.currentNativeHandle()) |current| {
        if (current == native_handle) {
            return error.ScreenshotRequiresWorkerThread;
        }
    }

    const request = try createUiScreenshotRequest(target, surface_id, working_dir);
    if (!postAgentUiScreenshot(native_handle, request)) {
        destroyUiScreenshotRequest(request);
        return error.WindowUnavailable;
    }
    return waitUiScreenshotRequest(request, allocator);
}

pub fn focusTerminal(ctx: *anyopaque, allocator: std.mem.Allocator, surface_id: []const u8) anyerror!ai_chat.ToolSurface {
    const host = try installedHost();
    const native_handle = host.nativeHandleForContext(ctx) orelse return error.WindowUnavailable;

    var request = AgentTerminalFocusRequest{
        .allocator = allocator,
        .surface_id = surface_id,
    };

    if (host.currentNativeHandle()) |current| {
        if (current == native_handle) {
            handleTerminalFocusRequest(&request, host);
        } else {
            postAgentTerminalFocus(native_handle, &request);
        }
    } else {
        postAgentTerminalFocus(native_handle, &request);
    }

    if (request.err) |err| return err;
    return request.result orelse error.SurfaceNotFound;
}

fn agentTabCommand(kind_raw: []const u8, command_raw: ?[]const u8) anyerror!?[]const u8 {
    return platform_pty_command.tabCommandForKind(kind_raw, command_raw, tab.getShellCmd());
}

pub fn handleTabNewRequest(request: *AgentTabNewRequest, host: Host) void {
    const command = agentTabCommand(request.kind, request.command) catch |err| {
        request.err = err;
        return;
    };

    const surface = if (command) |cmd|
        host.spawnTabWithCommand(cmd)
    else
        host.spawnDefaultTab();

    const new_surface = surface orelse {
        request.err = error.SpawnFailed;
        return;
    };

    const location = surface_snapshots.findAgentSurfaceLocation(new_surface) orelse {
        request.err = error.SpawnFailed;
        return;
    };
    request.result = surface_snapshots.makeAgentToolSurface(
        request.allocator,
        new_surface,
        location.tab_index,
        location.focused,
    ) catch |err| {
        request.err = err;
        return;
    };
}

fn findTabIndexBySurfaceId(surface_id: []const u8) ?usize {
    for (0..tab.g_tab_count) |tab_index| {
        const tab_state = tab.g_tabs[tab_index] orelse continue;
        if (tab_state.kind != .terminal) continue;
        var it = tab_state.tree.surfaces();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.surface.remote_id[0..], surface_id)) return tab_index;
        }
    }
    return null;
}

fn findTabIndexByTitle(title_text: []const u8) ?usize {
    const title_trimmed = std.mem.trim(u8, title_text, " \t\r\n");
    if (title_trimmed.len == 0) return null;

    for (0..tab.g_tab_count) |tab_index| {
        const tab_state = tab.g_tabs[tab_index] orelse continue;
        if (std.ascii.eqlIgnoreCase(tab_state.getTitle(), title_trimmed)) return tab_index;
    }

    var partial: ?usize = null;
    var partial_count: usize = 0;
    for (0..tab.g_tab_count) |tab_index| {
        const tab_state = tab.g_tabs[tab_index] orelse continue;
        if (std.ascii.indexOfIgnoreCase(tab_state.getTitle(), title_trimmed) != null) {
            partial = tab_index;
            partial_count += 1;
        }
    }
    return if (partial_count == 1) partial else null;
}

fn resolveAgentCloseTabIndex(request: *const AgentTabCloseRequest) ?usize {
    if (request.tab_index) |idx| return idx;
    if (request.surface_id) |surface_id| {
        if (findTabIndexBySurfaceId(surface_id)) |idx| return idx;
    }
    if (request.title) |title_text| {
        if (findTabIndexByTitle(title_text)) |idx| return idx;
    }
    return active_tab_state.g_active_tab;
}

pub fn handleTabCloseRequest(request: *AgentTabCloseRequest, host: Host) void {
    if (tab.g_tab_count <= 1) {
        request.err = error.LastTab;
        return;
    }

    const idx = resolveAgentCloseTabIndex(request) orelse {
        request.err = error.TabNotFound;
        return;
    };
    if (idx >= tab.g_tab_count) {
        request.err = error.TabNotFound;
        return;
    }

    const tab_state = tab.g_tabs[idx] orelse {
        request.err = error.TabNotFound;
        return;
    };
    if (tab_state.kind != .terminal) {
        request.err = error.CannotCloseAiChatTab;
        return;
    }

    const title_copy = request.allocator.dupe(u8, tab_state.getTitle()) catch |err| {
        request.err = err;
        return;
    };

    host.closeTabByIndex(idx);
    request.result = .{
        .tab_index = idx,
        .active_tab = active_tab_state.g_active_tab,
        .title = title_copy,
    };
}

pub fn handleSshConnectRequest(request: *AgentSshConnectRequest, host: Host) void {
    switch (host.connectSshProfile(request.profile_name)) {
        .connected => |surface| {
            const location = surface_snapshots.findAgentSurfaceLocation(surface) orelse {
                request.err = error.ConnectFailed;
                return;
            };
            request.result = surface_snapshots.makeAgentToolSurface(
                request.allocator,
                surface,
                location.tab_index,
                location.focused,
            ) catch |err| {
                request.err = err;
                return;
            };
        },
        .not_found => request.err = error.ProfileNotFound,
        .failed => request.err = error.ConnectFailed,
    }
}

pub fn handleSshSaveRequest(request: *AgentSshSaveRequest, host: Host) void {
    request.result = host.saveSshProfile(request.allocator, request.args) catch |err| {
        request.err = err;
        return;
    };
}

pub fn handleUiScreenshotRequest(request: *AgentUiScreenshotRequest, host: Host) void {
    _ = host;
    request.mutex.lock();
    const abandoned = request.abandoned;
    request.mutex.unlock();
    if (abandoned) {
        destroyUiScreenshotRequest(request);
        return;
    }
    enqueueUiScreenshotRequest(request);
}

pub fn handleTerminalFocusRequest(request: *AgentTerminalFocusRequest, host: Host) void {
    request.result = host.focusTerminalSurface(request.allocator, request.surface_id) catch |err| {
        request.err = err;
        return;
    };
}
