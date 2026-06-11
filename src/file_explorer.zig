//! File Explorer state and directory tree model.
//!
//! Manages the left-side file explorer sidebar: visibility, width, directory
//! scanning, tree expand/collapse, selection, scroll, and file operations.
//! Supports local (std.fs), WSL, and remote SSH/SCP modes.

const std = @import("std");
const ssh_connection = @import("ssh_connection.zig");
const agent_history = @import("agent_history.zig");
const scp = @import("scp.zig");
const file_backend = @import("file_backend.zig");
const platform_local_path = @import("platform/local_path.zig");
const ui_perf = @import("ui_perf.zig");
const active_tab_state = @import("appwindow/active_tab.zig");

pub const DEFAULT_WIDTH: f32 = 240;
pub const MIN_WIDTH: f32 = 160;
pub const MAX_WIDTH: f32 = 720;
pub const MIN_CONTENT_WIDTH: f32 = 240;
pub const RESIZE_HIT_WIDTH: f32 = 8;
pub const ROW_HEIGHT: f32 = 24;
pub const HEADER_HEIGHT: f32 = 36;
pub const INDENT_WIDTH: f32 = 16;
pub const MAX_ENTRIES: usize = 2048;
pub const MAX_HISTORY_ROWS: usize = 256;

pub const Mode = enum { local, wsl, remote };
pub const PanelMode = enum { files, agent_history };

pub const HistoryRow = struct {
    title_buf: [128]u8 = undefined,
    title_len: u8 = 0,
    model_buf: [64]u8 = undefined,
    model_len: u8 = 0,
    updated_at: i64 = 0,
};

pub const TerminalPanelTarget = union(enum) {
    remote: struct {
        conn: *const ssh_connection.SshConnection,
        cwd: []const u8,
    },
    wsl: []const u8,
    local: []const u8,
};

pub threadlocal var g_visible: bool = false;
pub threadlocal var g_owner_tab: ?usize = null;
pub threadlocal var g_width: f32 = DEFAULT_WIDTH;
pub threadlocal var g_focused: bool = false;
pub threadlocal var g_mode: Mode = .local;
pub threadlocal var g_panel_mode: PanelMode = .files;
pub threadlocal var g_row_height: f32 = ROW_HEIGHT;
pub threadlocal var g_header_height: f32 = HEADER_HEIGHT;

// Remote SSH connection state (copied from surface when entering remote mode)
pub threadlocal var g_ssh_conn: ssh_connection.SshConnection = .{};
pub threadlocal var g_has_ssh_conn: bool = false;

// Transfer status
pub threadlocal var g_transfer_status: TransferStatus = .idle;
pub threadlocal var g_transfer_msg: [128]u8 = undefined;
pub threadlocal var g_transfer_msg_len: u8 = 0;
pub threadlocal var g_transfer_time: i64 = 0;
pub threadlocal var g_loading: bool = false;
pub threadlocal var g_loading_msg: [128]u8 = undefined;
pub threadlocal var g_loading_msg_len: u8 = 0;

pub const TransferStatus = enum { idle, in_progress, success, failed, cancelled };
pub const TransferKind = enum { upload, download };

pub const TransferNotification = struct {
    seq: u64,
    kind: TransferKind,
    status: TransferStatus,
    message: []const u8,
};

pub threadlocal var g_transfer_notification_seq: u64 = 0;
threadlocal var g_transfer_notification_kind: TransferKind = .download;
threadlocal var g_transfer_notification_status: TransferStatus = .idle;
threadlocal var g_transfer_notification_msg: [128]u8 = undefined;
threadlocal var g_transfer_notification_msg_len: u8 = 0;

// Scroll state
pub threadlocal var g_scroll_offset: f32 = 0;
pub threadlocal var g_history_scroll_offset: f32 = 0;
pub threadlocal var g_visible_height: f32 = 400;
pub threadlocal var g_history_visible_height: f32 = 400;

// Selection state (index into flattened visible entries)
pub threadlocal var g_selected: ?usize = null;
pub threadlocal var g_history_rows: [MAX_HISTORY_ROWS]HistoryRow = undefined;
pub threadlocal var g_history_session_ids: [MAX_HISTORY_ROWS]?[]u8 = [_]?[]u8{null} ** MAX_HISTORY_ROWS;
pub threadlocal var g_history_row_count: usize = 0;
pub threadlocal var g_history_selected: ?usize = null;

// Root directory (UTF-8 path)
pub threadlocal var g_root_path: [260]u8 = undefined;
pub threadlocal var g_root_path_len: usize = 0;

// Flat list of currently visible entries (rebuilt on expand/collapse/rescan)
pub threadlocal var g_entries: [MAX_ENTRIES]FlatEntry = undefined;
pub threadlocal var g_entry_count: usize = 0;

const AsyncListKind = enum { rescan, expand };

const AsyncListJob = struct {
    kind: AsyncListKind,
    conn: ssh_connection.SshConnection,
    context_id: u64,
    path_buf: [512]u8 = undefined,
    path_len: usize = 0,
    depth: u16 = 0,
    resolve_root: bool = false,
    root_buf: [512]u8 = undefined,
    root_len: usize = 0,
    entries: []file_backend.Entry,
    status: file_backend.ListStatus = .ssh_failed,
    count: usize = 0,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,
};

const PendingAsyncList = struct {
    kind: AsyncListKind,
    context_id: u64,
    path_buf: [512]u8 = undefined,
    path_len: usize = 0,
    depth: u16 = 0,
    resolve_root: bool = false,
};

const AsyncListStart = enum { started, queued, blocked };

threadlocal var g_async_job: ?*AsyncListJob = null;
threadlocal var g_pending_async_list: ?PendingAsyncList = null;
threadlocal var g_async_context_id: u64 = 1;

const TransferFn = *const fn (std.mem.Allocator, *const ssh_connection.SshConnection, []const u8, []const u8, *scp.TransferControl) scp.TransferResult;
pub const TransferSuccessCallback = *const fn (?*anyopaque) void;
pub const TransferDestroyCallback = *const fn (?*anyopaque) void;
const TRANSFER_PATH_MAX: usize = 1024;
const TRANSFER_DISPLAY_MAX: usize = 128;

pub const TransferCompletion = struct {
    context: ?*anyopaque = null,
    on_success: ?TransferSuccessCallback = null,
    on_destroy: ?TransferDestroyCallback = null,
};

const TransferRequest = struct {
    kind: TransferKind,
    conn: ssh_connection.SshConnection,
    context_id: u64,
    src_buf: [TRANSFER_PATH_MAX]u8 = undefined,
    src_len: usize = 0,
    dst_buf: [TRANSFER_PATH_MAX]u8 = undefined,
    dst_len: usize = 0,
    display_buf: [TRANSFER_DISPLAY_MAX]u8 = undefined,
    display_len: usize = 0,
    transfer_fn: TransferFn,
    completion: TransferCompletion = .{},
};

const TransferJob = struct {
    request: TransferRequest,
    control: scp.TransferControl = .{},
    result: scp.TransferResult = .failed,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,
    last_progress_ms: i64 = 0,
    last_progress_bytes: ?u64 = null,
};

threadlocal var g_transfer_job: ?*TransferJob = null;
threadlocal var g_transfer_queue: std.ArrayListUnmanaged(TransferRequest) = .empty;

pub const FlatEntry = struct {
    name_buf: [256]u8 = undefined,
    name_len: u8 = 0,
    is_dir: bool = false,
    expanded: bool = false,
    depth: u16 = 0,
    // Full relative path for operations
    path_buf: [512]u8 = undefined,
    path_len: u16 = 0,
};

pub fn width() f32 {
    return if (isVisibleForActiveTab()) g_width else 0;
}

pub fn isVisibleForActiveTab() bool {
    const owner = g_owner_tab orelse return false;
    return g_visible and owner == active_tab_state.g_active_tab;
}

pub fn openForActiveTab() void {
    g_visible = true;
    g_owner_tab = active_tab_state.g_active_tab;
}

pub fn close() void {
    g_visible = false;
    g_owner_tab = null;
    g_focused = false;
}

pub fn onTabClosed(closed_idx: usize) void {
    const owner = g_owner_tab orelse return;
    if (owner == closed_idx) {
        close();
    } else if (owner > closed_idx) {
        g_owner_tab = owner - 1;
    }
}

pub fn onTabReordered(from_idx: usize, to_idx: usize) void {
    const owner = g_owner_tab orelse return;
    if (owner == from_idx) {
        g_owner_tab = to_idx;
    } else if (from_idx < to_idx and owner > from_idx and owner <= to_idx) {
        g_owner_tab = owner - 1;
    } else if (from_idx > to_idx and owner >= to_idx and owner < from_idx) {
        g_owner_tab = owner + 1;
    }
}

pub fn syncLayoutMetrics(text_height: f32) void {
    g_row_height = @max(ROW_HEIGHT, @round(text_height + 8));
    g_header_height = @max(HEADER_HEIGHT, @round(text_height + 16));
}

pub fn syncViewportMetrics(window_height: f32, titlebar_h: f32) void {
    const visible_height = @max(0, window_height - titlebar_h - headerHeight());
    g_visible_height = visible_height;
    g_history_visible_height = visible_height;
    clampFileScroll();
    clampHistoryScroll();
}

pub fn rowHeight() f32 {
    return g_row_height;
}

pub fn headerHeight() f32 {
    return g_header_height;
}

pub fn maxWidthForWindow(window_width: f32) f32 {
    return @max(MIN_WIDTH, @min(MAX_WIDTH, window_width - MIN_CONTENT_WIDTH));
}

pub fn clampWidth(w: f32, window_width: f32) f32 {
    return @max(MIN_WIDTH, @min(maxWidthForWindow(window_width), w));
}

pub fn setWidth(w: f32, window_width: f32) bool {
    const next = clampWidth(w, window_width);
    if (next == g_width) return false;
    g_width = next;
    return true;
}

pub fn toggle() void {
    if (isVisibleForActiveTab()) {
        close();
    } else {
        openForActiveTab();
    }
}

pub fn setPanelMode(mode: PanelMode) void {
    if (mode == .agent_history) clearFileOpState();
    if (g_panel_mode == mode) {
        switch (mode) {
            .files => clampFileScroll(),
            .agent_history => {
                clampHistorySelection();
                clampHistoryScroll();
            },
        }
        return;
    }
    g_panel_mode = mode;
    switch (mode) {
        .files => clampFileScroll(),
        .agent_history => {
            clampHistorySelection();
            clampHistoryScroll();
        },
    }
}

pub fn syncPanelForTabKind(is_ai_tab: bool) void {
    g_focused = false;
    setPanelMode(if (is_ai_tab) .agent_history else .files);
}

pub fn syncPanelForTerminalTarget(target: TerminalPanelTarget, force: bool) void {
    const matches = terminalTargetMatchesCurrentState(target);
    if (matches and !force) return;

    if (!matches) applyTerminalTargetState(target);

    if (matches and force) {
        // Re-opening the same target: force a rescan but keep the selection.
        refresh();
    } else {
        switch (target) {
            .remote => rescanRemote(),
            .wsl, .local => {
                if (g_root_path_len > 0) rescan();
            },
        }
    }
}

pub fn syncAgentHistoryRows(store: *const agent_history.Store) void {
    const allocator = std.heap.page_allocator;
    const selected_index_copy = g_history_selected;
    const selected_session_id_copy = if (g_history_selected) |selected|
        if (historySessionIdAt(selected)) |session_id|
            allocator.dupe(u8, session_id) catch null
        else
            null
    else
        null;
    defer if (selected_session_id_copy) |session_id| allocator.free(session_id);

    const rows = store.buildRows(allocator) catch {
        clearHistoryRows();
        g_history_selected = null;
        g_history_scroll_offset = 0;
        return;
    };
    defer agent_history.freeRows(allocator, rows);

    clearHistoryRows();
    var filled: usize = 0;
    for (rows[0..@min(rows.len, g_history_rows.len)], 0..) |row, idx| {
        const owned_session_id = allocator.dupe(u8, row.session_id) catch break;
        g_history_session_ids[idx] = owned_session_id;
        copyHistoryText(&g_history_rows[idx].title_buf, &g_history_rows[idx].title_len, row.title);
        copyHistoryText(&g_history_rows[idx].model_buf, &g_history_rows[idx].model_len, row.model);
        g_history_rows[idx].updated_at = row.updated_at;
        filled += 1;
    }
    g_history_row_count = filled;

    if (selected_session_id_copy != null) {
        g_history_selected = null;
        for (0..g_history_row_count) |idx| {
            if (std.mem.eql(u8, historySessionIdAt(idx).?, selected_session_id_copy.?)) {
                g_history_selected = idx;
                break;
            }
        }
        if (g_history_selected == null and g_history_row_count > 0) {
            g_history_selected = @min(selected_index_copy.?, g_history_row_count - 1);
        }
    }

    clampHistorySelection();
    if (g_panel_mode == .agent_history) clampHistoryScroll();
}

pub fn moveHistorySelection(delta: i32) void {
    if (g_history_row_count == 0) {
        g_history_selected = null;
        return;
    }

    if (g_history_selected) |selected| {
        const next = @as(i32, @intCast(selected)) + delta;
        g_history_selected = @intCast(@max(0, @min(@as(i32, @intCast(g_history_row_count - 1)), next)));
    } else {
        g_history_selected = 0;
    }
    ensureHistorySelectedVisible();
}

pub fn historySessionIdAt(idx: usize) ?[]const u8 {
    if (idx >= g_history_row_count) return null;
    return g_history_session_ids[idx];
}

pub fn selectedHistorySessionId() ?[]const u8 {
    const selected = g_history_selected orelse return null;
    return historySessionIdAt(selected);
}

fn clampHistorySelection() void {
    if (g_history_row_count == 0) {
        g_history_selected = null;
        return;
    }

    if (g_history_selected) |selected| {
        if (selected >= g_history_row_count) {
            g_history_selected = g_history_row_count - 1;
        }
    }
}

fn copyHistoryText(buf: anytype, len_out: *u8, value: []const u8) void {
    var len: usize = 0;
    while (len < value.len and len < buf.len) {
        const seq_len = std.unicode.utf8ByteSequenceLength(value[len]) catch break;
        if (len + seq_len > value.len or len + seq_len > buf.len) break;
        @memcpy(buf[len .. len + seq_len], value[len .. len + seq_len]);
        len += seq_len;
    }
    len_out.* = @intCast(len);
}

fn ensureHistorySelectedVisible() void {
    const selected = g_history_selected orelse return;
    const row_h = rowHeight();
    const selected_top = @as(f32, @floatFromInt(selected)) * row_h;
    if (selected_top < g_history_scroll_offset) {
        g_history_scroll_offset = selected_top;
    } else if (selected_top + row_h > g_history_scroll_offset + g_history_visible_height) {
        g_history_scroll_offset = selected_top + row_h - g_history_visible_height;
    }
    clampHistoryScroll();
}

fn clampHistoryScroll() void {
    g_history_scroll_offset = @max(0, @min(maxHistoryScroll(), g_history_scroll_offset));
}

fn maxHistoryScroll() f32 {
    const total_h = @as(f32, @floatFromInt(g_history_row_count)) * rowHeight();
    return @max(0, total_h - g_history_visible_height);
}

fn clearHistoryRows() void {
    for (&g_history_session_ids) |*session_id| {
        if (session_id.*) |owned| std.heap.page_allocator.free(owned);
        session_id.* = null;
    }
    g_history_row_count = 0;
}

fn clearFileOpState() void {
    g_op_mode = .none;
    g_input_len = 0;
}

fn terminalTargetMatchesCurrentState(target: TerminalPanelTarget) bool {
    if (g_panel_mode != .files) return false;

    const current_root = g_root_path[0..g_root_path_len];
    return switch (target) {
        .remote => |remote| g_mode == .remote and
            g_has_ssh_conn and
            sshConnectionsEqual(&g_ssh_conn, remote.conn) and
            std.mem.eql(u8, current_root, remote.cwd),
        .wsl => |cwd| g_mode == .wsl and
            !g_has_ssh_conn and
            std.mem.eql(u8, current_root, if (cwd.len > 0) cwd else "~"),
        .local => |path| g_mode == .local and
            !g_has_ssh_conn and
            std.mem.eql(u8, current_root, path),
    };
}

fn sshConnectionsEqual(a: *const ssh_connection.SshConnection, b: *const ssh_connection.SshConnection) bool {
    return std.mem.eql(u8, a.user(), b.user()) and
        std.mem.eql(u8, a.host(), b.host()) and
        std.mem.eql(u8, a.port(), b.port()) and
        std.mem.eql(u8, a.password(), b.password()) and
        a.password_auth == b.password_auth and
        a.legacy_algorithms == b.legacy_algorithms;
}

fn applyTerminalTargetState(target: TerminalPanelTarget) void {
    syncPanelForTabKind(false);
    g_async_context_id +%= 1;
    g_pending_async_list = null;
    g_loading = false;
    g_entry_count = 0;
    g_selected = null;

    switch (target) {
        .remote => |remote| {
            g_mode = .remote;
            g_ssh_conn = remote.conn.*;
            g_has_ssh_conn = true;
            copyRootPathOnly(remote.cwd);
        },
        .wsl => |cwd| {
            g_mode = .wsl;
            g_has_ssh_conn = false;
            copyRootPathOnly(if (cwd.len > 0) cwd else "~");
        },
        .local => |path| {
            g_mode = .local;
            g_has_ssh_conn = false;
            copyRootPathOnly(path);
        },
    }
}

fn copyRootPathOnly(path: []const u8) void {
    const len = @min(path.len, g_root_path.len);
    @memcpy(g_root_path[0..len], path[0..len]);
    g_root_path_len = len;
}

/// Enter remote mode with the given SSH connection.
pub fn enterRemoteMode(conn: *const ssh_connection.SshConnection, remote_cwd: []const u8) void {
    g_async_context_id +%= 1;
    g_mode = .remote;
    g_ssh_conn = conn.*;
    g_has_ssh_conn = true;
    if (remote_cwd.len > 0) {
        setRoot(remote_cwd);
    } else {
        g_root_path_len = 0;
        rescanRemote();
    }
}

/// Switch back to local mode.
pub fn enterLocalMode() void {
    g_async_context_id +%= 1;
    g_pending_async_list = null;
    g_loading = false;
    g_mode = .local;
    g_has_ssh_conn = false;
    g_entry_count = 0;
    g_root_path_len = 0;
}

/// Enter WSL mode. Paths are Linux-style and listed via the platform backend.
pub fn enterWslMode(wsl_cwd: []const u8) void {
    g_async_context_id +%= 1;
    g_pending_async_list = null;
    g_loading = false;
    g_mode = .wsl;
    g_has_ssh_conn = false;
    if (wsl_cwd.len > 0) {
        setRoot(wsl_cwd);
    } else {
        setRoot("~");
    }
}

pub fn setRoot(path: []const u8) void {
    g_async_context_id +%= 1;
    const len = @min(path.len, g_root_path.len);
    @memcpy(g_root_path[0..len], path[0..len]);
    g_root_path_len = len;
    if (g_mode == .remote and g_has_ssh_conn) {
        rescanRemote();
    } else {
        rescan();
    }
}

pub fn tickAsync() bool {
    const before_transfer_seq = g_transfer_notification_seq;
    tickTransferJob();
    var changed = g_transfer_notification_seq != before_transfer_seq;

    const job = g_async_job orelse return changed;
    if (!job.done.load(.acquire)) return changed;

    if (job.thread) |thread| thread.join();
    g_async_job = null;
    g_loading = false;
    changed = true;
    defer maybeStartPendingAsyncList();
    defer destroyAsyncJob(job);

    if (job.context_id != g_async_context_id or g_mode != .remote or !g_has_ssh_conn) {
        return changed;
    }

    if (job.status != .ok) {
        setTransferStatus(.failed, if (job.resolve_root) "SSH pwd failed" else "SSH list failed");
        if (job.kind == .expand) {
            if (findEntryByPath(job.path_buf[0..job.path_len])) |idx| {
                g_entries[idx].expanded = false;
            }
        }
        return true;
    }

    switch (job.kind) {
        .rescan => {
            if (job.resolve_root) {
                const root_len = @min(job.root_len, g_root_path.len);
                @memcpy(g_root_path[0..root_len], job.root_buf[0..root_len]);
                g_root_path_len = root_len;
            }
            g_entry_count = 0;
            g_scroll_offset = 0;
            g_selected = null;
            const root = g_root_path[0..g_root_path_len];
            _ = insertBackendChildren(0, job.entries[0..job.count], 0, root, '/');
            applyRefreshRestore();
        },
        .expand => {
            const path = job.path_buf[0..job.path_len];
            const idx = findEntryByPath(path) orelse return true;
            if (!g_entries[idx].expanded) return true;
            _ = insertBackendChildren(idx + 1, job.entries[0..job.count], job.depth, path, '/');
        },
    }
    return true;
}

// Manual-refresh restore state: capture selection (by path) + scroll before a
// rescan rebuilds the flat list, then re-apply once the list is ready. Only
// refresh() sets `pending`, so ordinary rescans (tab switch, etc.) never restore.
threadlocal var g_refresh_restore_pending: bool = false;
threadlocal var g_refresh_keep_path: [512]u8 = undefined;
threadlocal var g_refresh_keep_path_len: u16 = 0;
threadlocal var g_refresh_keep_scroll: f32 = 0;

pub fn rescan() void {
    const perf = ui_perf.begin("file_explorer.rescan");
    defer perf.end();

    g_entry_count = 0;
    g_scroll_offset = 0;
    g_selected = null;

    if (g_mode == .remote and g_has_ssh_conn) {
        rescanRemote();
        return;
    }

    if (g_root_path_len == 0) return;

    const path = g_root_path[0..g_root_path_len];
    const backend: file_backend.Backend = switch (g_mode) {
        .local => .local,
        .wsl => .wsl,
        .remote => unreachable,
    };
    const sep: u8 = if (g_mode == .wsl) '/' else platform_local_path.separator();
    const result = loadBackendEntries(backend, path, 0, path, sep);
    if (result != .ok) {
        setTransferStatus(.failed, if (g_mode == .wsl) "WSL list failed" else "Cannot open folder");
    }
}

/// Scan remote directory via the configured SSH backend.
pub fn rescanRemote() void {
    const perf = ui_perf.begin("file_explorer.rescan_remote");
    defer perf.end();

    g_entry_count = 0;
    g_scroll_offset = 0;
    g_selected = null;

    if (!g_has_ssh_conn) return;

    if (g_root_path_len == 0) {
        if (startAsyncList(.rescan, "", 0, true) == .blocked) {
            setTransferStatus(.failed, "SSH list busy");
        }
        return;
    }

    const path = g_root_path[0..g_root_path_len];
    if (startAsyncList(.rescan, path, 0, false) == .blocked) {
        setTransferStatus(.failed, "SSH list busy");
    }
}

/// Manually re-list the current directory, preserving selection (by path) and
/// scroll where possible. Works for local, WSL, and remote (SSH) modes.
/// For remote, the list is rebuilt asynchronously and the restore is applied
/// when the rescan job completes in tickAsync().
pub fn refresh() void {
    g_refresh_restore_pending = true;
    g_refresh_keep_scroll = g_scroll_offset;
    g_refresh_keep_path_len = 0;
    if (g_selected) |sel| {
        if (sel < g_entry_count) {
            const p = g_entries[sel].path_buf[0..g_entries[sel].path_len];
            const n: u16 = @intCast(@min(p.len, g_refresh_keep_path.len));
            @memcpy(g_refresh_keep_path[0..n], p[0..n]);
            g_refresh_keep_path_len = n;
        }
    }

    rescan();

    if (g_mode == .remote and g_has_ssh_conn) {
        // Async rebuild: rescanRemote() started or queued a job, whose tickAsync
        // completion runs applyRefreshRestore() and clears `pending`.
        if (g_async_job != null or g_pending_async_list != null) {
            setTransferStatus(.in_progress, "Refreshing…");
        } else {
            // startAsyncList failed to enqueue (e.g. OOM): no completion will
            // consume the pending restore, so clear it to avoid leaking a stale
            // selection onto a future rescan.
            g_refresh_restore_pending = false;
        }
    } else {
        applyRefreshRestore();
    }
}

fn applyRefreshRestore() void {
    if (!g_refresh_restore_pending) return;
    g_refresh_restore_pending = false;

    g_selected = null;
    if (g_refresh_keep_path_len > 0) {
        if (findEntryByPath(g_refresh_keep_path[0..g_refresh_keep_path_len])) |idx| {
            g_selected = idx;
        }
    }
    g_scroll_offset = g_refresh_keep_scroll;
    clampFileScroll();
    if (g_selected != null) ensureSelectedVisible();
    setTransferStatus(.success, "Refreshed");
}

fn loadBackendEntries(
    backend: file_backend.Backend,
    path: []const u8,
    depth: u16,
    parent_path: []const u8,
    sep: u8,
) file_backend.ListStatus {
    const perf = ui_perf.begin("file_explorer.load_backend_entries");
    defer perf.end();

    const capacity = g_entries.len - g_entry_count;
    if (capacity == 0) return .ok;

    const allocator = std.heap.page_allocator;
    const entries = allocator.alloc(file_backend.Entry, capacity) catch return .open_failed;
    defer allocator.free(entries);

    const result = file_backend.list(allocator, backend, path, entries);
    if (result.status != .ok) return result.status;

    for (entries[0..result.count]) |*entry| {
        if (g_entry_count >= g_entries.len) break;
        if (copyBackendEntry(&g_entries[g_entry_count], entry, depth, parent_path, sep)) {
            g_entry_count += 1;
        }
    }

    return .ok;
}

fn copyBackendEntry(
    dest: *FlatEntry,
    src: *const file_backend.Entry,
    depth: u16,
    parent_path: []const u8,
    sep: u8,
) bool {
    const name = src.name();
    const name_len: u8 = @intCast(@min(name.len, 255));
    @memcpy(dest.name_buf[0..name_len], name[0..name_len]);
    dest.name_len = name_len;
    dest.is_dir = src.is_dir;
    dest.expanded = false;
    dest.depth = depth;

    const path_len = buildChildPathInto(&dest.path_buf, parent_path, name[0..name_len], sep) orelse return false;
    dest.path_len = @intCast(path_len);
    return true;
}

fn buildChildPathInto(buf: *[512]u8, parent: []const u8, name: []const u8, sep: u8) ?usize {
    if (parent.len > buf.len) return null;
    var pos: usize = 0;
    @memcpy(buf[0..parent.len], parent);
    pos = parent.len;

    const add_sep = parent.len > 0 and !pathEndsWithSeparator(parent, sep);
    if (add_sep) {
        if (pos >= buf.len) return null;
        buf[pos] = sep;
        pos += 1;
    }

    if (pos + name.len > buf.len) return null;
    @memcpy(buf[pos..][0..name.len], name);
    pos += name.len;
    return pos;
}

fn pathEndsWithSeparator(path: []const u8, sep: u8) bool {
    return platform_local_path.endsWithSeparatorForSeparator(path, sep);
}

pub fn toggleExpand(idx: usize) void {
    if (idx >= g_entry_count) return;
    if (!g_entries[idx].is_dir) return;

    if (g_entries[idx].expanded) {
        collapse(idx);
    } else {
        if (g_mode == .remote and g_has_ssh_conn) {
            expandRemote(idx);
        } else if (g_mode == .wsl) {
            expandWsl(idx);
        } else {
            expand(idx);
        }
    }
}

fn expandRemote(idx: usize) void {
    const entry = &g_entries[idx];
    entry.expanded = true;
    const path = entry.path_buf[0..entry.path_len];
    if (startAsyncList(.expand, path, entry.depth + 1, false) == .blocked) {
        entry.expanded = false;
        setTransferStatus(.failed, "SSH list busy");
    }
}

fn expandWithBackend(idx: usize, backend: file_backend.Backend, sep: u8) void {
    const entry = &g_entries[idx];
    entry.expanded = true;

    const path = entry.path_buf[0..entry.path_len];
    const child_depth = entry.depth + 1;
    const insert_pos = idx + 1;
    const max_new = g_entries.len - g_entry_count;
    if (max_new == 0) return;

    const allocator = std.heap.page_allocator;
    const backend_entries = allocator.alloc(file_backend.Entry, max_new) catch {
        entry.expanded = false;
        return;
    };
    defer allocator.free(backend_entries);

    const result = file_backend.list(allocator, backend, path, backend_entries);
    if (result.status != .ok) {
        entry.expanded = false;
        setTransferStatus(
            .failed,
            switch (g_mode) {
                .remote => "SSH list failed",
                .wsl => "WSL list failed",
                .local => "Cannot open folder",
            },
        );
        return;
    }

    const inserted = insertBackendChildren(insert_pos, backend_entries[0..result.count], child_depth, path, sep);
    if (inserted == 0) entry.expanded = false;
}

fn insertBackendChildren(
    insert_pos: usize,
    backend_entries: []const file_backend.Entry,
    child_depth: u16,
    parent_path: []const u8,
    sep: u8,
) usize {
    if (backend_entries.len == 0) return 0;
    if (g_entry_count >= g_entries.len) return 0;

    const allocator = std.heap.page_allocator;
    const max_new = g_entries.len - g_entry_count;
    const flat_children = allocator.alloc(FlatEntry, @min(backend_entries.len, max_new)) catch {
        return 0;
    };
    defer allocator.free(flat_children);

    var filled: usize = 0;
    for (backend_entries) |*child| {
        if (filled >= flat_children.len) break;
        if (copyBackendEntry(&flat_children[filled], child, child_depth, parent_path, sep)) {
            filled += 1;
        }
    }

    if (filled == 0) return 0;

    if (insert_pos < g_entry_count) {
        std.mem.copyBackwards(
            FlatEntry,
            g_entries[insert_pos + filled .. g_entry_count + filled],
            g_entries[insert_pos..g_entry_count],
        );
    }

    @memcpy(g_entries[insert_pos .. insert_pos + filled], flat_children[0..filled]);
    g_entry_count += filled;
    return filled;
}

fn findEntryByPath(path: []const u8) ?usize {
    for (0..g_entry_count) |idx| {
        const entry_path = g_entries[idx].path_buf[0..g_entries[idx].path_len];
        if (std.mem.eql(u8, entry_path, path)) return idx;
    }
    return null;
}

fn startAsyncList(kind: AsyncListKind, path: []const u8, depth: u16, resolve_root: bool) AsyncListStart {
    if (!g_has_ssh_conn) return .blocked;
    if (path.len > 512) return .blocked;
    if (g_async_job != null) return queueAsyncList(kind, path, depth, resolve_root);

    const allocator = std.heap.page_allocator;
    const entries = allocator.alloc(file_backend.Entry, MAX_ENTRIES) catch return .blocked;
    const job = allocator.create(AsyncListJob) catch {
        allocator.free(entries);
        return .blocked;
    };

    job.* = .{
        .kind = kind,
        .conn = g_ssh_conn,
        .context_id = g_async_context_id,
        .path_len = path.len,
        .depth = depth,
        .resolve_root = resolve_root,
        .entries = entries,
    };
    @memcpy(job.path_buf[0..path.len], path);

    const thread = std.Thread.spawn(.{}, asyncListThread, .{job}) catch {
        allocator.free(entries);
        allocator.destroy(job);
        return .blocked;
    };
    job.thread = thread;
    g_async_job = job;
    setLoading(if (resolve_root) "remote folder" else path);
    return .started;
}

fn queueAsyncList(kind: AsyncListKind, path: []const u8, depth: u16, resolve_root: bool) AsyncListStart {
    if (path.len > 512) return .blocked;
    var pending = PendingAsyncList{
        .kind = kind,
        .context_id = g_async_context_id,
        .path_len = path.len,
        .depth = depth,
        .resolve_root = resolve_root,
    };
    @memcpy(pending.path_buf[0..path.len], path);
    g_pending_async_list = pending;
    setLoading(if (resolve_root) "remote folder" else path);
    return .queued;
}

fn maybeStartPendingAsyncList() void {
    if (g_async_job != null) return;
    const pending = g_pending_async_list orelse return;
    g_pending_async_list = null;

    if (pending.context_id != g_async_context_id or g_mode != .remote or !g_has_ssh_conn) {
        return;
    }

    const path = pending.path_buf[0..pending.path_len];
    if (startAsyncList(pending.kind, path, pending.depth, pending.resolve_root) == .blocked) {
        setTransferStatus(.failed, "SSH list failed");
    }
}

fn asyncListThread(job: *AsyncListJob) void {
    const allocator = std.heap.page_allocator;
    var path = job.path_buf[0..job.path_len];

    if (job.resolve_root) {
        const root_len = file_backend.resolveRoot(allocator, .{ .ssh = &job.conn }, &job.root_buf) orelse {
            job.status = .ssh_failed;
            job.done.store(true, .release);
            return;
        };
        job.root_len = root_len;
        path = job.root_buf[0..root_len];
    }

    const result = file_backend.list(allocator, .{ .ssh = &job.conn }, path, job.entries);
    job.status = result.status;
    job.count = result.count;
    job.done.store(true, .release);
}

fn destroyAsyncJob(job: *AsyncListJob) void {
    const allocator = std.heap.page_allocator;
    allocator.free(job.entries);
    allocator.destroy(job);
}

fn startTransferJob(kind: TransferKind, conn: *const ssh_connection.SshConnection, src: []const u8, dst: []const u8, display: []const u8, transfer_fn: TransferFn) bool {
    return startTransferJobWithCompletion(kind, conn, src, dst, display, transfer_fn, .{});
}

fn startTransferJobWithCompletion(kind: TransferKind, conn: *const ssh_connection.SshConnection, src: []const u8, dst: []const u8, display: []const u8, transfer_fn: TransferFn, completion: TransferCompletion) bool {
    if (src.len > TRANSFER_PATH_MAX or dst.len > TRANSFER_PATH_MAX) {
        destroyTransferCompletion(completion);
        setTransferStatusForKind(kind, .failed, "Path too long");
        return false;
    }

    var request = TransferRequest{
        .kind = kind,
        .conn = conn.*,
        .context_id = g_async_context_id,
        .src_len = src.len,
        .dst_len = dst.len,
        .display_len = @min(display.len, TRANSFER_DISPLAY_MAX),
        .transfer_fn = transfer_fn,
        .completion = completion,
    };
    @memcpy(request.src_buf[0..src.len], src);
    @memcpy(request.dst_buf[0..dst.len], dst);
    @memcpy(request.display_buf[0..request.display_len], display[0..request.display_len]);

    return startTransferRequest(request);
}

fn startTransferRequest(request: TransferRequest) bool {
    if (g_transfer_job != null) {
        g_transfer_queue.append(std.heap.page_allocator, request) catch {
            destroyTransferRequest(request);
            setTransferStatusForKind(request.kind, .failed, "Transfer queue full");
            return false;
        };
        return true;
    }
    return startTransferRequestNow(request);
}

fn startTransferRequestNow(request: TransferRequest) bool {
    const allocator = std.heap.page_allocator;
    const job = allocator.create(TransferJob) catch {
        destroyTransferRequest(request);
        setTransferStatusForKind(request.kind, .failed, "Transfer start failed");
        return false;
    };

    job.* = .{
        .request = request,
    };

    const thread = std.Thread.spawn(.{}, transferThread, .{job}) catch {
        allocator.destroy(job);
        destroyTransferRequest(request);
        setTransferStatusForKind(request.kind, .failed, "Transfer start failed");
        return false;
    };
    job.thread = thread;
    g_transfer_job = job;
    initializeTransferProgress(job, std.time.milliTimestamp());
    publishTransferInProgress(job, null);
    return true;
}

fn transferThread(job: *TransferJob) void {
    const allocator = std.heap.page_allocator;
    const dst = job.request.dst_buf[0..job.request.dst_len];
    // Snapshot dst existence before scp runs: on cancel only a path this
    // transfer created may be deleted. A pre-existing dst holds user data
    // (scp -r nests into an existing same-name directory; a file dst may be
    // an earlier completed download) and must survive.
    const cleanup_on_cancel = job.request.kind == .download and !localPathExists(dst);
    job.result = job.request.transfer_fn(
        allocator,
        &job.request.conn,
        job.request.src_buf[0..job.request.src_len],
        dst,
        &job.control,
    );
    // Cleanup runs here, on the worker thread, so deleting a large partial
    // tree never stalls the UI tick; done is stored after, so the next queued
    // transfer cannot race the deletion.
    if (job.result == .cancelled and cleanup_on_cancel) removePartialDownload(dst);
    job.done.store(true, .release);
}

fn tickTransferJob() void {
    const job = g_transfer_job orelse return;
    if (!job.done.load(.acquire)) {
        if (job.control.cancelRequested()) {
            const display = job.request.display_buf[0..job.request.display_len];
            setTransferStatusForKind(job.request.kind, .cancelled, display);
            return;
        }
        updateTransferProgress(job, std.time.milliTimestamp());
        return;
    }

    if (job.thread) |thread| thread.join();
    g_transfer_job = null;
    defer destroyTransferJob(job);
    defer maybeStartNextTransfer();

    const display = job.request.display_buf[0..job.request.display_len];
    switch (job.result) {
        .ok => {
            setTransferStatusForKind(job.request.kind, .success, display);
            if (job.request.completion.on_success) |callback| callback(job.request.completion.context);
            if (job.request.kind == .upload and job.request.context_id == g_async_context_id and g_mode == .remote and g_has_ssh_conn) {
                rescanRemote();
            }
        },
        .cancelled => setTransferStatusForKind(job.request.kind, .cancelled, display),
        else => setTransferStatusForKind(job.request.kind, .failed, display),
    }
}

fn initializeTransferProgress(job: *TransferJob, now_ms: i64) void {
    job.last_progress_ms = now_ms;
    job.last_progress_bytes = observedTransferBytes(job);
}

fn updateTransferProgress(job: *TransferJob, now_ms: i64) void {
    if (job.request.kind != .download) return;
    if (now_ms - job.last_progress_ms < 500) return;

    const current_bytes = observedTransferBytes(job) orelse {
        job.last_progress_ms = now_ms;
        publishTransferInProgress(job, null);
        return;
    };

    const previous_bytes = job.last_progress_bytes orelse {
        job.last_progress_ms = now_ms;
        job.last_progress_bytes = current_bytes;
        publishTransferInProgress(job, null);
        return;
    };

    const elapsed_ms = @max(1, now_ms - job.last_progress_ms);
    const delta = if (current_bytes >= previous_bytes) current_bytes - previous_bytes else 0;
    const bytes_per_sec = delta * 1000 / @as(u64, @intCast(elapsed_ms));
    job.last_progress_ms = now_ms;
    job.last_progress_bytes = current_bytes;
    publishTransferInProgress(job, bytes_per_sec);
}

fn publishTransferInProgress(job: *TransferJob, bytes_per_sec: ?u64) void {
    const display = job.request.display_buf[0..job.request.display_len];
    if (job.request.kind != .download) {
        setTransferStatusForKind(job.request.kind, .in_progress, display);
        return;
    }

    var msg_buf: [128]u8 = undefined;
    const msg = formatTransferProgressMessage(&msg_buf, display, bytes_per_sec) catch display;
    setTransferStatusForKind(job.request.kind, .in_progress, msg);
}

fn observedTransferBytes(job: *const TransferJob) ?u64 {
    if (job.request.kind != .download) return null;
    const path = job.request.dst_buf[0..job.request.dst_len];
    return localFileSize(path);
}

fn localFileSize(path: []const u8) ?u64 {
    var file = if (std.fs.path.isAbsolute(path))
        std.fs.openFileAbsolute(path, .{}) catch return null
    else
        std.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();
    const info = file.stat() catch return null;
    // A directory destination (folder download) has no meaningful byte count;
    // returning null lets the progress toast show "calculating…".
    if (info.kind == .directory) return null;
    return info.size;
}

fn formatTransferProgressMessage(buf: []u8, display: []const u8, bytes_per_sec: ?u64) ![]u8 {
    if (bytes_per_sec) |speed| {
        var speed_buf: [32]u8 = undefined;
        const speed_text = try formatTransferRate(&speed_buf, speed);
        return std.fmt.bufPrint(buf, "{s} - {s}", .{ display, speed_text });
    }
    return std.fmt.bufPrint(buf, "{s} - calculating...", .{display});
}

fn formatTransferRate(buf: []u8, bytes_per_sec: u64) ![]u8 {
    const kb = 1024.0;
    const mb = 1024.0 * 1024.0;
    const gb = 1024.0 * 1024.0 * 1024.0;
    const speed: f64 = @floatFromInt(bytes_per_sec);
    if (bytes_per_sec < 1024) return std.fmt.bufPrint(buf, "{d} B/s", .{bytes_per_sec});
    if (speed < mb) return std.fmt.bufPrint(buf, "{d:.1} KB/s", .{speed / kb});
    if (speed < gb) return std.fmt.bufPrint(buf, "{d:.1} MB/s", .{speed / mb});
    return std.fmt.bufPrint(buf, "{d:.1} GB/s", .{speed / gb});
}

fn localPathExists(path: []const u8) bool {
    if (path.len == 0) return false;
    if (std.fs.path.isAbsolute(path)) {
        std.fs.accessAbsolute(path, .{}) catch return false;
    } else {
        std.fs.cwd().access(path, .{}) catch return false;
    }
    return true;
}

/// Remove a partially-transferred download destination — a half-written file or
/// an incomplete folder tree. Best-effort: any error (e.g. already gone) is
/// ignored.
fn removePartialDownload(path: []const u8) void {
    if (path.len == 0) return;
    if (std.fs.path.isAbsolute(path)) {
        std.fs.deleteTreeAbsolute(path) catch {};
    } else {
        std.fs.cwd().deleteTree(path) catch {};
    }
}

pub fn cancelActiveTransfer() bool {
    const job = g_transfer_job orelse return false;
    if (job.request.kind != .download) return false;
    if (job.done.load(.acquire)) return false;
    job.control.cancel();
    const display = job.request.display_buf[0..job.request.display_len];
    setTransferStatusForKind(job.request.kind, .cancelled, display);
    return true;
}

fn maybeStartNextTransfer() void {
    while (g_transfer_job == null and g_transfer_queue.items.len > 0) {
        const next = g_transfer_queue.orderedRemove(0);
        if (startTransferRequestNow(next)) return;
    }
}

fn destroyTransferRequest(request: TransferRequest) void {
    destroyTransferCompletion(request.completion);
}

fn destroyTransferCompletion(completion: TransferCompletion) void {
    if (completion.on_destroy) |callback| callback(completion.context);
}

fn destroyTransferJob(job: *TransferJob) void {
    destroyTransferRequest(job.request);
    std.heap.page_allocator.destroy(job);
}

fn startTransferJobForTest(kind: TransferKind, conn: *const ssh_connection.SshConnection, src: []const u8, dst: []const u8, display: []const u8, transfer_fn: TransferFn) bool {
    return startTransferJob(kind, conn, src, dst, display, transfer_fn);
}

fn tickTransferJobForTest() void {
    tickTransferJob();
}

fn transferQueueLenForTest() usize {
    return g_transfer_queue.items.len;
}

fn cancelActiveDownloadForTest() bool {
    return cancelActiveTransfer();
}

fn formatTransferProgressMessageForTest(buf: []u8, display: []const u8, bytes_per_sec: ?u64) ![]u8 {
    return formatTransferProgressMessage(buf, display, bytes_per_sec);
}

fn resetTransferStateForTest() void {
    if (g_transfer_job) |job| {
        if (job.thread) |thread| thread.join();
        destroyTransferJob(job);
        g_transfer_job = null;
    }
    for (g_transfer_queue.items) |request| destroyTransferRequest(request);
    g_transfer_queue.clearRetainingCapacity();
    g_transfer_status = .idle;
    g_transfer_msg_len = 0;
    g_transfer_notification_seq = 0;
    g_transfer_notification_msg_len = 0;
}

fn latestTransferNotificationForTest() ?TransferNotification {
    return latestTransferNotification();
}

/// Clean up any in-flight async job. Call on window close to avoid leaking
/// the job allocation and its thread.
pub fn deinit() void {
    if (g_transfer_job) |job| {
        if (job.thread) |thread| thread.join();
        destroyTransferJob(job);
        g_transfer_job = null;
    }
    for (g_transfer_queue.items) |request| destroyTransferRequest(request);
    g_transfer_queue.clearAndFree(std.heap.page_allocator);
    g_transfer_notification_seq = 0;
    g_transfer_notification_msg_len = 0;
    if (g_async_job) |job| {
        // Wait for the background thread to finish
        if (job.thread) |thread| thread.join();
        destroyAsyncJob(job);
        g_async_job = null;
    }
    g_pending_async_list = null;
    g_loading = false;
    clearHistoryRows();
}

fn setLoading(msg: []const u8) void {
    g_loading = true;
    g_loading_msg_len = @intCast(@min(msg.len, g_loading_msg.len));
    @memcpy(g_loading_msg[0..g_loading_msg_len], msg[0..g_loading_msg_len]);
}

fn expand(idx: usize) void {
    expandWithBackend(idx, .local, platform_local_path.separator());
}

fn expandWsl(idx: usize) void {
    expandWithBackend(idx, .wsl, '/');
}

fn collapse(idx: usize) void {
    var entry = &g_entries[idx];
    entry.expanded = false;

    // Remove all entries after idx with depth > entry.depth
    const base_depth = entry.depth;
    var end = idx + 1;
    while (end < g_entry_count and g_entries[end].depth > base_depth) {
        end += 1;
    }

    const remove_count = end - (idx + 1);
    if (remove_count == 0) return;

    // Shift remaining entries up
    const remaining = g_entry_count - end;
    var k: usize = 0;
    while (k < remaining) : (k += 1) {
        g_entries[idx + 1 + k] = g_entries[end + k];
    }
    g_entry_count -= remove_count;

    // Adjust selection
    if (g_selected) |sel| {
        if (sel > idx and sel < end) {
            g_selected = idx;
        } else if (sel >= end) {
            g_selected = sel - remove_count;
        }
    }
}

pub fn scrollBy(delta: f32) void {
    switch (g_panel_mode) {
        .files => {
            const max_scroll = maxScroll();
            g_scroll_offset = @max(0, @min(max_scroll, g_scroll_offset + delta));
        },
        .agent_history => {
            const max_scroll = maxHistoryScroll();
            g_history_scroll_offset = @max(0, @min(max_scroll, g_history_scroll_offset + delta));
        },
    }
}

fn maxScroll() f32 {
    const total_h = @as(f32, @floatFromInt(g_entry_count)) * rowHeight();
    return @max(0, total_h - g_visible_height);
}

fn clampFileScroll() void {
    g_scroll_offset = @max(0, @min(maxScroll(), g_scroll_offset));
}

// ============================================================================
// File Operations
// ============================================================================

pub const OpMode = enum { none, rename, new_file, new_dir, confirm_delete };

pub threadlocal var g_op_mode: OpMode = .none;
pub threadlocal var g_input_buf: [256]u8 = undefined;
pub threadlocal var g_input_len: u8 = 0;

pub fn startRename() void {
    const sel = g_selected orelse return;
    if (sel >= g_entry_count) return;
    g_op_mode = .rename;
    const entry = &g_entries[sel];
    @memcpy(g_input_buf[0..entry.name_len], entry.name_buf[0..entry.name_len]);
    g_input_len = entry.name_len;
}

pub fn startNewFile() void {
    g_op_mode = .new_file;
    g_input_len = 0;
}

pub fn startNewDir() void {
    g_op_mode = .new_dir;
    g_input_len = 0;
}

pub fn startDelete() void {
    if (g_selected == null) return;
    g_op_mode = .confirm_delete;
}

pub fn cancelOp() void {
    g_op_mode = .none;
    g_input_len = 0;
}

pub fn commitOp() void {
    switch (g_op_mode) {
        .rename => commitRename(),
        .new_file => commitNewFile(),
        .new_dir => commitNewDir(),
        .confirm_delete => commitDelete(),
        .none => {},
    }
    g_op_mode = .none;
    g_input_len = 0;
}

fn commitRename() void {
    const sel = g_selected orelse return;
    if (sel >= g_entry_count) return;
    if (g_input_len == 0) return;

    const entry = &g_entries[sel];
    const old_path = entry.path_buf[0..entry.path_len];
    const new_name = g_input_buf[0..g_input_len];

    var new_path_buf: [512]u8 = undefined;
    const parent_end = platform_local_path.parentPrefixLen(old_path);
    if (parent_end + new_name.len > new_path_buf.len) return;
    @memcpy(new_path_buf[0..parent_end], old_path[0..parent_end]);
    @memcpy(new_path_buf[parent_end..][0..new_name.len], new_name);
    const new_path = new_path_buf[0 .. parent_end + new_name.len];

    // Perform rename via std.fs
    const cwd = std.fs.cwd();
    cwd.rename(old_path, new_path) catch return;

    rescan();
}

fn commitNewFile() void {
    if (g_input_len == 0) return;
    const new_name = g_input_buf[0..g_input_len];
    const parent = getSelectedParentPath();

    var path_buf: [512]u8 = undefined;
    const path = buildChildPath(&path_buf, parent, new_name) orelse return;

    const cwd = std.fs.cwd();
    const file = cwd.createFile(path, .{}) catch return;
    file.close();

    rescan();
}

fn commitNewDir() void {
    if (g_input_len == 0) return;
    const new_name = g_input_buf[0..g_input_len];
    const parent = getSelectedParentPath();

    var path_buf: [512]u8 = undefined;
    const path = buildChildPath(&path_buf, parent, new_name) orelse return;

    const cwd = std.fs.cwd();
    cwd.makeDir(path) catch return;

    rescan();
}

fn commitDelete() void {
    const sel = g_selected orelse return;
    if (sel >= g_entry_count) return;

    const entry = &g_entries[sel];
    const path = entry.path_buf[0..entry.path_len];

    const cwd = std.fs.cwd();
    if (entry.is_dir) {
        cwd.deleteTree(path) catch return;
    } else {
        cwd.deleteFile(path) catch return;
    }

    rescan();
}

fn getSelectedParentPath() []const u8 {
    if (g_selected) |sel| {
        if (sel < g_entry_count) {
            const entry = &g_entries[sel];
            if (entry.is_dir and entry.expanded) {
                return entry.path_buf[0..entry.path_len];
            }
            const path = entry.path_buf[0..entry.path_len];
            if (platform_local_path.parent(path)) |parent_path| return parent_path;
        }
    }
    return g_root_path[0..g_root_path_len];
}

fn buildChildPath(buf: *[512]u8, parent: []const u8, name: []const u8) ?[]const u8 {
    return platform_local_path.joinInto(buf[0..], parent, name);
}

pub fn inputChar(cp: u21) void {
    if (g_op_mode == .none or g_op_mode == .confirm_delete) return;
    if (g_input_len >= 255) return;
    // Encode codepoint to UTF-8
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(cp, &buf) catch return;
    if (@as(usize, g_input_len) + len > 255) return;
    @memcpy(g_input_buf[g_input_len..][0..len], buf[0..len]);
    g_input_len += @intCast(len);
}

pub fn inputBackspace() void {
    if (g_op_mode == .none or g_op_mode == .confirm_delete) return;
    if (g_input_len == 0) return;
    // Remove last UTF-8 char
    var i: u8 = g_input_len - 1;
    while (i > 0 and (g_input_buf[i] & 0xC0) == 0x80) i -= 1;
    g_input_len = i;
}

pub fn moveSelection(delta: i32) void {
    if (g_entry_count == 0) return;
    if (g_selected) |sel| {
        const new = @as(i32, @intCast(sel)) + delta;
        g_selected = @intCast(@max(0, @min(@as(i32, @intCast(g_entry_count - 1)), new)));
    } else {
        g_selected = 0;
    }
    ensureSelectedVisible();
}

fn ensureSelectedVisible() void {
    const sel = g_selected orelse return;
    const row_h = rowHeight();
    const sel_top = @as(f32, @floatFromInt(sel)) * row_h;
    if (sel_top < g_scroll_offset) {
        g_scroll_offset = sel_top;
    } else if (sel_top + row_h > g_scroll_offset + g_visible_height) {
        g_scroll_offset = sel_top + row_h - g_visible_height;
    }
    clampFileScroll();
}

// ============================================================================
// SCP Transfer Operations
// ============================================================================

pub fn setTransferStatus(status: TransferStatus, msg: []const u8) void {
    g_transfer_status = status;
    g_transfer_msg_len = @intCast(@min(msg.len, g_transfer_msg.len));
    @memcpy(g_transfer_msg[0..g_transfer_msg_len], msg[0..g_transfer_msg_len]);
    g_transfer_time = std.time.milliTimestamp();
}

pub fn setTransferStatusForKind(kind: TransferKind, status: TransferStatus, msg: []const u8) void {
    setTransferStatus(status, msg);
    publishTransferNotification(kind, status, msg);
}

fn publishTransferNotification(kind: TransferKind, status: TransferStatus, msg: []const u8) void {
    g_transfer_notification_seq +%= 1;
    if (g_transfer_notification_seq == 0) g_transfer_notification_seq = 1;
    g_transfer_notification_kind = kind;
    g_transfer_notification_status = status;
    g_transfer_notification_msg_len = @intCast(@min(msg.len, g_transfer_notification_msg.len));
    @memcpy(g_transfer_notification_msg[0..g_transfer_notification_msg_len], msg[0..g_transfer_notification_msg_len]);
}

pub fn latestTransferNotification() ?TransferNotification {
    if (g_transfer_notification_seq == 0) return null;
    return .{
        .seq = g_transfer_notification_seq,
        .kind = g_transfer_notification_kind,
        .status = g_transfer_notification_status,
        .message = g_transfer_notification_msg[0..g_transfer_notification_msg_len],
    };
}

/// Choose the transfer function for a download based on whether the selected
/// entry is a directory (recursive `scp -r`) or a regular file.
fn pickDownloadTransferFn(is_dir: bool) TransferFn {
    return if (is_dir) scp.transferDirWithControl else scp.transferWithControl;
}

/// Remote entry names come from `ls -1p` output, where `\` is a legal file
/// name byte but a path separator on Windows: a hostile remote can smuggle
/// `..\..\name` to steer the download destination — and the cancel cleanup's
/// recursive delete — outside the chosen directory. Reject separators and
/// `..` outright before a local path is built from the name.
fn isSafeDownloadEntryName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.mem.indexOfAny(u8, name, "/\\") != null) return false;
    if (std.mem.indexOf(u8, name, "..") != null) return false;
    return true;
}

/// Download the selected remote file or directory to a local directory.
pub fn downloadSelected(local_dir: []const u8) void {
    if (g_mode != .remote or !g_has_ssh_conn) return;
    const sel = g_selected orelse return;
    if (sel >= g_entry_count) return;

    const entry = &g_entries[sel];

    const name = entry.name_buf[0..entry.name_len];
    if (!isSafeDownloadEntryName(name)) {
        setTransferStatusForKind(.download, .failed, "Unsafe file name");
        return;
    }

    const remote_path = entry.path_buf[0..entry.path_len];

    // Build remote spec: user@host:path
    var spec_buf: [512]u8 = undefined;
    const src = scp.remoteSpec(&spec_buf, &g_ssh_conn, remote_path);

    var dst_buf: [512]u8 = undefined;
    const dst = platform_local_path.joinInto(dst_buf[0..], local_dir, name) orelse {
        setTransferStatusForKind(.download, .failed, "Path too long");
        return;
    };

    _ = startTransferJob(.download, &g_ssh_conn, src, dst, name, pickDownloadTransferFn(entry.is_dir));
}

/// Upload a local file to the current remote directory.
pub fn uploadFile(local_path: []const u8) void {
    if (g_mode != .remote or !g_has_ssh_conn) return;

    // Destination: current remote dir
    const remote_dir = g_root_path[0..g_root_path_len];

    var spec_buf: [512]u8 = undefined;
    const dst = scp.remoteSpec(&spec_buf, &g_ssh_conn, remote_dir);

    const filename = platform_local_path.basename(local_path);

    _ = startTransferJob(.upload, &g_ssh_conn, local_path, dst, filename, scp.transferWithControl);
}

/// Upload a local folder (recursively) to the current remote directory.
pub fn uploadFolder(local_path: []const u8) void {
    if (g_mode != .remote or !g_has_ssh_conn) return;

    // Destination: current remote dir
    const remote_dir = g_root_path[0..g_root_path_len];

    var spec_buf: [512]u8 = undefined;
    const dst = scp.remoteSpec(&spec_buf, &g_ssh_conn, remote_dir);

    const name = platform_local_path.basename(local_path);

    _ = startTransferJob(.upload, &g_ssh_conn, local_path, dst, name, scp.transferDirWithControl);
}

pub fn uploadLocalFileToRemoteSpec(local_path: []const u8, dst_spec: []const u8, display_name: []const u8, conn: *const ssh_connection.SshConnection) bool {
    return uploadLocalFileToRemoteSpecWithTransfer(local_path, dst_spec, display_name, conn, scp.transferWithControl);
}

fn uploadLocalFileToRemoteSpecWithTransfer(local_path: []const u8, dst_spec: []const u8, display_name: []const u8, conn: *const ssh_connection.SshConnection, transfer_fn: TransferFn) bool {
    return startTransferJob(.upload, conn, local_path, dst_spec, display_name, transfer_fn);
}

fn uploadLocalFileToRemoteSpecWithTransferAndCallback(
    local_path: []const u8,
    dst_spec: []const u8,
    display_name: []const u8,
    conn: *const ssh_connection.SshConnection,
    transfer_fn: TransferFn,
    callback: TransferSuccessCallback,
) bool {
    return startTransferJobWithCompletion(.upload, conn, local_path, dst_spec, display_name, transfer_fn, .{ .on_success = callback });
}

pub fn uploadLocalFileToRemoteSpecWithCompletion(
    local_path: []const u8,
    dst_spec: []const u8,
    display_name: []const u8,
    conn: *const ssh_connection.SshConnection,
    completion: TransferCompletion,
) bool {
    return startTransferJobWithCompletion(.upload, conn, local_path, dst_spec, display_name, scp.transferWithControl, completion);
}

pub fn downloadRemoteFileToPath(remote_path: []const u8, local_path: []const u8, display_name: []const u8, conn: *const ssh_connection.SshConnection) bool {
    return downloadRemoteFileToPathWithTransfer(remote_path, local_path, display_name, conn, scp.transferWithControl);
}

fn downloadRemoteFileToPathWithTransfer(remote_path: []const u8, local_path: []const u8, display_name: []const u8, conn: *const ssh_connection.SshConnection, transfer_fn: TransferFn) bool {
    if (conn.user_len + conn.host_len + remote_path.len + 2 > 512) {
        setTransferStatusForKind(.download, .failed, "Path too long");
        return false;
    }

    var spec_buf: [512]u8 = undefined;
    const src = scp.remoteSpec(&spec_buf, conn, remote_path);
    return startTransferJob(.download, conn, src, local_path, display_name, transfer_fn);
}

// ============================================================================
// Tests
// ============================================================================

test "setTransferStatus stores message" {
    setTransferStatus(.success, "test_file.txt");
    try std.testing.expectEqual(TransferStatus.success, g_transfer_status);
    try std.testing.expectEqualStrings("test_file.txt", g_transfer_msg[0..g_transfer_msg_len]);
}

fn transferOkForTest(_: std.mem.Allocator, _: *const ssh_connection.SshConnection, _: []const u8, _: []const u8, _: *scp.TransferControl) scp.TransferResult {
    return .ok;
}

threadlocal var g_transfer_success_callback_count_for_test: usize = 0;

fn transferSuccessCallbackForTest(_: ?*anyopaque) void {
    g_transfer_success_callback_count_for_test += 1;
}

fn tickTransfersUntilIdleForTest() void {
    var attempts: usize = 0;
    while ((g_transfer_job != null or transferQueueLenForTest() > 0) and attempts < 200) : (attempts += 1) {
        tickTransferJobForTest();
        if (g_transfer_job != null) std.Thread.sleep(std.time.ns_per_ms);
    }
}

test "file_explorer: transfer job starts without completing on input thread" {
    resetTransferStateForTest();
    defer resetTransferStateForTest();

    var conn: ssh_connection.SshConnection = .{};
    try std.testing.expect(startTransferJobForTest(.download, &conn, "remote", "local", "file.txt", transferOkForTest));
    try std.testing.expectEqual(TransferStatus.in_progress, g_transfer_status);
    try std.testing.expectEqualStrings("file.txt - calculating...", g_transfer_msg[0..g_transfer_msg_len]);
    try std.testing.expect(g_transfer_job != null);
}

test "file_explorer: completed transfer job updates status on tick" {
    resetTransferStateForTest();
    defer resetTransferStateForTest();

    var conn: ssh_connection.SshConnection = .{};
    try std.testing.expect(startTransferJobForTest(.download, &conn, "remote", "local", "file.txt", transferOkForTest));

    var attempts: usize = 0;
    while (g_transfer_job != null and attempts < 100) : (attempts += 1) {
        tickTransferJobForTest();
        if (g_transfer_job != null) std.Thread.sleep(std.time.ns_per_ms);
    }

    try std.testing.expectEqual(@as(?*TransferJob, null), g_transfer_job);
    try std.testing.expectEqual(TransferStatus.success, g_transfer_status);
    try std.testing.expectEqualStrings("file.txt", g_transfer_msg[0..g_transfer_msg_len]);
}

test "file_explorer: second transfer is queued while one is active" {
    resetTransferStateForTest();
    defer resetTransferStateForTest();

    var conn: ssh_connection.SshConnection = .{};
    try std.testing.expect(startTransferJobForTest(.download, &conn, "remote-a", "local-a", "a.txt", transferOkForTest));
    try std.testing.expect(startTransferJobForTest(.upload, &conn, "local-b", "remote-b", "b.txt", transferOkForTest));
    try std.testing.expectEqual(@as(usize, 1), transferQueueLenForTest());

    tickTransfersUntilIdleForTest();

    try std.testing.expectEqual(@as(?*TransferJob, null), g_transfer_job);
    try std.testing.expectEqual(@as(usize, 0), transferQueueLenForTest());
    try std.testing.expectEqual(TransferStatus.success, g_transfer_status);
    try std.testing.expectEqualStrings("b.txt", g_transfer_msg[0..g_transfer_msg_len]);
}

test "file_explorer: transfer success callback is deferred until upload succeeds" {
    resetTransferStateForTest();
    defer resetTransferStateForTest();
    g_transfer_success_callback_count_for_test = 0;

    var conn: ssh_connection.SshConnection = .{};
    try std.testing.expect(uploadLocalFileToRemoteSpecWithTransferAndCallback(
        "local.txt",
        "user@host:/tmp",
        "local.txt",
        &conn,
        transferOkForTest,
        transferSuccessCallbackForTest,
    ));

    try std.testing.expectEqual(@as(usize, 0), g_transfer_success_callback_count_for_test);

    tickTransfersUntilIdleForTest();

    try std.testing.expectEqual(@as(usize, 1), g_transfer_success_callback_count_for_test);
}

test "file_explorer: upload helper starts transfer with explicit remote spec" {
    resetTransferStateForTest();
    defer resetTransferStateForTest();

    var conn: ssh_connection.SshConnection = .{};
    try std.testing.expect(uploadLocalFileToRemoteSpecWithTransfer("local.txt", "user@host:/tmp", "local.txt", &conn, transferOkForTest));
    try std.testing.expectEqual(TransferStatus.in_progress, g_transfer_status);
    try std.testing.expectEqualStrings("local.txt", g_transfer_msg[0..g_transfer_msg_len]);
    try std.testing.expect(g_transfer_job != null);
}

test "file_explorer: download helper starts transfer with explicit remote path" {
    resetTransferStateForTest();
    defer resetTransferStateForTest();

    var conn: ssh_connection.SshConnection = .{};
    conn.user_buf[0] = 'u';
    conn.user_len = 1;
    conn.host_buf[0] = 'h';
    conn.host_len = 1;

    try std.testing.expect(downloadRemoteFileToPathWithTransfer("/tmp/file.txt", "C:\\Users\\me\\Downloads\\file.txt", "file.txt", &conn, transferOkForTest));
    try std.testing.expectEqual(TransferStatus.in_progress, g_transfer_status);
    try std.testing.expectEqualStrings("file.txt - calculating...", g_transfer_msg[0..g_transfer_msg_len]);
    try std.testing.expect(g_transfer_job != null);
}

test "file_explorer: download picks recursive transfer for directories" {
    try std.testing.expectEqual(
        @as(TransferFn, scp.transferDirWithControl),
        pickDownloadTransferFn(true),
    );
    try std.testing.expectEqual(
        @as(TransferFn, scp.transferWithControl),
        pickDownloadTransferFn(false),
    );
}

test "file_explorer: isSafeDownloadEntryName rejects separators and dot-dot" {
    try std.testing.expect(isSafeDownloadEntryName("report.txt"));
    try std.testing.expect(isSafeDownloadEntryName("data dir"));
    try std.testing.expect(isSafeDownloadEntryName(".hidden"));

    try std.testing.expect(!isSafeDownloadEntryName(""));
    try std.testing.expect(!isSafeDownloadEntryName(".."));
    try std.testing.expect(!isSafeDownloadEntryName("..\\..\\evil"));
    try std.testing.expect(!isSafeDownloadEntryName("a\\b"));
    try std.testing.expect(!isSafeDownloadEntryName("a/b"));
    try std.testing.expect(!isSafeDownloadEntryName("archive..tar"));
}

test "file_explorer: download refuses remote entry names that can escape the destination dir" {
    resetTransferStateForTest();
    defer resetTransferStateForTest();
    defer {
        g_mode = .local;
        g_has_ssh_conn = false;
        g_ssh_conn = .{};
        g_entry_count = 0;
        g_selected = null;
    }

    g_mode = .remote;
    g_has_ssh_conn = true;
    g_ssh_conn = .{};
    g_selected = 0;
    g_entry_count = 1;
    g_entries[0] = .{};
    const evil_name = "..\\..\\evil";
    @memcpy(g_entries[0].name_buf[0..evil_name.len], evil_name);
    g_entries[0].name_len = evil_name.len;
    const evil_path = "/srv/..\\..\\evil";
    @memcpy(g_entries[0].path_buf[0..evil_path.len], evil_path);
    g_entries[0].path_len = evil_path.len;

    downloadSelected("/tmp/wispterm-test-downloads");

    try std.testing.expectEqual(@as(?*TransferJob, null), g_transfer_job);
    try std.testing.expectEqual(TransferStatus.failed, g_transfer_status);
}

test "file_explorer: download transfer emits notification" {
    resetTransferStateForTest();
    defer resetTransferStateForTest();

    var conn: ssh_connection.SshConnection = .{};
    conn.user_buf[0] = 'u';
    conn.user_len = 1;
    conn.host_buf[0] = 'h';
    conn.host_len = 1;
    try std.testing.expect(downloadRemoteFileToPathWithTransfer("/tmp/file.txt", "C:\\Users\\me\\Downloads\\file.txt", "file.txt", &conn, transferOkForTest));

    const notification = latestTransferNotificationForTest() orelse return error.MissingTransferNotification;
    try std.testing.expectEqual(TransferKind.download, notification.kind);
    try std.testing.expectEqual(TransferStatus.in_progress, notification.status);
    try std.testing.expectEqualStrings("file.txt - calculating...", notification.message);
}

test "file_explorer: download progress message includes transfer speed" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "file.txt - calculating...",
        try formatTransferProgressMessageForTest(&buf, "file.txt", null),
    );
    try std.testing.expectEqualStrings(
        "file.txt - 1.5 KB/s",
        try formatTransferProgressMessageForTest(&buf, "file.txt", 1536),
    );
    try std.testing.expectEqualStrings(
        "file.txt - 2.0 MB/s",
        try formatTransferProgressMessageForTest(&buf, "file.txt", 2 * 1024 * 1024),
    );
}

fn transferWaitForCancelForTest(_: std.mem.Allocator, _: *const ssh_connection.SshConnection, _: []const u8, _: []const u8, control: *scp.TransferControl) scp.TransferResult {
    var attempts: usize = 0;
    while (!control.cancelRequested() and attempts < 200) : (attempts += 1) {
        std.Thread.sleep(std.time.ns_per_ms);
    }
    return if (control.cancelRequested()) .cancelled else .failed;
}

test "file_explorer: active download transfer can be cancelled" {
    resetTransferStateForTest();
    defer resetTransferStateForTest();

    // dst must not be a relative path: cancel cleanup deletes the dst tree,
    // and a cwd-relative name could collide with a real directory.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);
    const dst = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "file.txt" });
    defer std.testing.allocator.free(dst);

    var conn: ssh_connection.SshConnection = .{};
    try std.testing.expect(startTransferJobForTest(.download, &conn, "remote", dst, "file.txt", transferWaitForCancelForTest));
    try std.testing.expect(cancelActiveDownloadForTest());

    tickTransfersUntilIdleForTest();

    try std.testing.expectEqual(@as(?*TransferJob, null), g_transfer_job);
    try std.testing.expectEqual(TransferStatus.cancelled, g_transfer_status);
    try std.testing.expectEqualStrings("file.txt", g_transfer_msg[0..g_transfer_msg_len]);
}

fn transferCreateDstThenWaitForCancelForTest(allocator: std.mem.Allocator, conn: *const ssh_connection.SshConnection, src: []const u8, dst: []const u8, control: *scp.TransferControl) scp.TransferResult {
    if (std.fs.createFileAbsolute(dst, .{})) |file| {
        file.close();
    } else |_| {}
    return transferWaitForCancelForTest(allocator, conn, src, dst, control);
}

test "file_explorer: cancelling a download deletes the partial destination it created" {
    resetTransferStateForTest();
    defer resetTransferStateForTest();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);
    const dst = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "partial.bin" });
    defer std.testing.allocator.free(dst);

    var conn: ssh_connection.SshConnection = .{};
    try std.testing.expect(startTransferJobForTest(.download, &conn, "remote", dst, "partial.bin", transferCreateDstThenWaitForCancelForTest));
    try std.testing.expect(cancelActiveDownloadForTest());

    tickTransfersUntilIdleForTest();

    try std.testing.expectEqual(TransferStatus.cancelled, g_transfer_status);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("partial.bin", .{}));
}

test "file_explorer: cancelling a download preserves a pre-existing destination" {
    resetTransferStateForTest();
    defer resetTransferStateForTest();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "existing.bin", .data = "precious" });
    const dst = try tmp.dir.realpathAlloc(std.testing.allocator, "existing.bin");
    defer std.testing.allocator.free(dst);

    var conn: ssh_connection.SshConnection = .{};
    try std.testing.expect(startTransferJobForTest(.download, &conn, "remote", dst, "existing.bin", transferWaitForCancelForTest));
    try std.testing.expect(cancelActiveDownloadForTest());

    tickTransfersUntilIdleForTest();

    try std.testing.expectEqual(TransferStatus.cancelled, g_transfer_status);
    const contents = try tmp.dir.readFileAlloc(std.testing.allocator, "existing.bin", 64);
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings("precious", contents);
}

test "buildChildPathInto avoids duplicate separators" {
    var buf: [512]u8 = undefined;

    const remote = buildChildPathInto(&buf, "/var/log", "syslog", '/') orelse unreachable;
    try std.testing.expectEqualStrings("/var/log/syslog", buf[0..remote]);

    const remote_root = buildChildPathInto(&buf, "/", "home", '/') orelse unreachable;
    try std.testing.expectEqualStrings("/home", buf[0..remote_root]);
}

test "Mode enum values" {
    try std.testing.expectEqual(Mode.local, .local);
    try std.testing.expectEqual(Mode.wsl, .wsl);
    try std.testing.expectEqual(Mode.remote, .remote);
    // Default state
    g_mode = .local;
    try std.testing.expect(!g_has_ssh_conn);
}

test "file_explorer: visible only on owning active tab" {
    const saved_visible = g_visible;
    const saved_owner = g_owner_tab;
    const saved_focused = g_focused;
    const saved_active_tab = active_tab_state.g_active_tab;
    defer {
        g_visible = saved_visible;
        g_owner_tab = saved_owner;
        g_focused = saved_focused;
        active_tab_state.g_active_tab = saved_active_tab;
    }

    active_tab_state.g_active_tab = 0;
    openForActiveTab();

    try std.testing.expect(isVisibleForActiveTab());
    try std.testing.expectEqual(DEFAULT_WIDTH, width());

    active_tab_state.g_active_tab = 1;
    try std.testing.expect(!isVisibleForActiveTab());
    try std.testing.expectEqual(@as(f32, 0), width());

    active_tab_state.g_active_tab = 0;
    try std.testing.expect(isVisibleForActiveTab());
}

test "file_explorer: owner follows tab close and reorder" {
    const saved_visible = g_visible;
    const saved_owner = g_owner_tab;
    const saved_focused = g_focused;
    const saved_active_tab = active_tab_state.g_active_tab;
    defer {
        g_visible = saved_visible;
        g_owner_tab = saved_owner;
        g_focused = saved_focused;
        active_tab_state.g_active_tab = saved_active_tab;
    }

    g_visible = true;
    g_owner_tab = 2;
    onTabClosed(1);
    try std.testing.expectEqual(@as(?usize, 1), g_owner_tab);

    active_tab_state.g_active_tab = 1;
    try std.testing.expect(isVisibleForActiveTab());

    onTabReordered(1, 3);
    try std.testing.expectEqual(@as(?usize, 3), g_owner_tab);

    onTabReordered(0, 2);
    try std.testing.expectEqual(@as(?usize, 3), g_owner_tab);

    onTabClosed(3);
    try std.testing.expectEqual(@as(?usize, null), g_owner_tab);
    try std.testing.expect(!g_visible);
}

test "file_explorer: agent history mode selection clamps to row count" {
    g_panel_mode = .agent_history;
    g_history_row_count = 2;
    g_history_selected = 10;
    clampHistorySelection();
    try std.testing.expectEqual(@as(?usize, 1), g_history_selected);
}

test "file_explorer: history selection visibility uses history viewport height" {
    g_panel_mode = .agent_history;
    g_row_height = 20;
    g_history_visible_height = 60;
    g_history_row_count = 10;
    g_history_scroll_offset = 0;
    g_history_selected = 4;
    ensureHistorySelectedVisible();
    try std.testing.expectEqual(@as(f32, 40), g_history_scroll_offset);
}

test "file_explorer: moveHistorySelection walks selected row" {
    g_panel_mode = .agent_history;
    g_row_height = 20;
    g_history_visible_height = 200;
    g_history_row_count = 3;
    g_history_selected = 0;
    g_history_scroll_offset = 0;

    moveHistorySelection(1);
    try std.testing.expectEqual(@as(?usize, 1), g_history_selected);

    moveHistorySelection(10);
    try std.testing.expectEqual(@as(?usize, 2), g_history_selected);
}

test "file_explorer: history scroll does not mutate file scroll" {
    g_panel_mode = .files;
    g_row_height = 20;
    g_visible_height = 100;
    g_entry_count = 10;
    g_scroll_offset = 30;
    scrollBy(10);
    try std.testing.expectEqual(@as(f32, 40), g_scroll_offset);

    g_panel_mode = .agent_history;
    g_history_visible_height = 60;
    g_history_row_count = 10;
    g_history_scroll_offset = 5;
    scrollBy(10);

    try std.testing.expectEqual(@as(f32, 40), g_scroll_offset);
    try std.testing.expectEqual(@as(f32, 15), g_history_scroll_offset);
}

test "file_explorer: switching to agent history clears file op state" {
    g_panel_mode = .files;
    g_op_mode = .rename;
    g_input_len = 3;
    g_scroll_offset = 77;
    g_history_scroll_offset = 12;

    setPanelMode(.agent_history);

    try std.testing.expectEqual(PanelMode.agent_history, g_panel_mode);
    try std.testing.expectEqual(OpMode.none, g_op_mode);
    try std.testing.expectEqual(@as(u8, 0), g_input_len);
    try std.testing.expectEqual(@as(f32, 77), g_scroll_offset);
    try std.testing.expectEqual(@as(f32, 12), g_history_scroll_offset);
}

test "file_explorer: syncPanelForTabKind resets focus and mode" {
    g_focused = true;
    g_panel_mode = .files;

    syncPanelForTabKind(true);
    try std.testing.expectEqual(false, g_focused);
    try std.testing.expectEqual(PanelMode.agent_history, g_panel_mode);

    g_focused = true;
    syncPanelForTabKind(false);
    try std.testing.expectEqual(false, g_focused);
    try std.testing.expectEqual(PanelMode.files, g_panel_mode);
}

test "file_explorer: applyTerminalTargetState updates terminal backend and root" {
    const conn: ssh_connection.SshConnection = .{
        .user_len = 4,
        .host_len = 4,
        .port_len = 2,
        .password_len = 2,
        .password_auth = true,
        .legacy_algorithms = false,
    };
    const saved_focused = g_focused;
    const saved_panel_mode = g_panel_mode;
    const saved_mode = g_mode;
    const saved_has_ssh_conn = g_has_ssh_conn;
    const saved_root_len = g_root_path_len;
    const saved_async_context = g_async_context_id;
    defer {
        g_focused = saved_focused;
        g_panel_mode = saved_panel_mode;
        g_mode = saved_mode;
        g_has_ssh_conn = saved_has_ssh_conn;
        g_root_path_len = saved_root_len;
        g_async_context_id = saved_async_context;
    }

    g_focused = true;
    applyTerminalTargetState(.{ .wsl = "/home/test" });
    try std.testing.expectEqual(false, g_focused);
    try std.testing.expectEqual(PanelMode.files, g_panel_mode);
    try std.testing.expectEqual(Mode.wsl, g_mode);
    try std.testing.expectEqualStrings("/home/test", g_root_path[0..g_root_path_len]);

    g_focused = true;
    applyTerminalTargetState(.{ .local = "C:\\Users\\tester" });
    try std.testing.expectEqual(false, g_focused);
    try std.testing.expectEqual(Mode.local, g_mode);
    try std.testing.expect(!g_has_ssh_conn);
    try std.testing.expectEqualStrings("C:\\Users\\tester", g_root_path[0..g_root_path_len]);

    g_focused = true;
    applyTerminalTargetState(.{ .remote = .{ .conn = &conn, .cwd = "/var/tmp" } });
    try std.testing.expectEqual(false, g_focused);
    try std.testing.expectEqual(Mode.remote, g_mode);
    try std.testing.expect(g_has_ssh_conn);
    try std.testing.expectEqualStrings("/var/tmp", g_root_path[0..g_root_path_len]);
}

test "file_explorer: unchanged terminal target preserves file state" {
    const saved_panel_mode = g_panel_mode;
    const saved_mode = g_mode;
    const saved_has_ssh_conn = g_has_ssh_conn;
    const saved_root_len = g_root_path_len;
    const saved_entry_count = g_entry_count;
    const saved_selected = g_selected;
    const saved_scroll_offset = g_scroll_offset;
    const saved_focused = g_focused;
    const saved_async_context = g_async_context_id;
    defer {
        g_panel_mode = saved_panel_mode;
        g_mode = saved_mode;
        g_has_ssh_conn = saved_has_ssh_conn;
        g_root_path_len = saved_root_len;
        g_entry_count = saved_entry_count;
        g_selected = saved_selected;
        g_scroll_offset = saved_scroll_offset;
        g_focused = saved_focused;
        g_async_context_id = saved_async_context;
    }

    g_panel_mode = .files;
    g_mode = .local;
    g_has_ssh_conn = false;
    copyRootPathOnly("");
    g_entry_count = 7;
    g_selected = 3;
    g_scroll_offset = 42;
    g_focused = true;
    g_async_context_id = 99;

    syncPanelForTerminalTarget(.{ .local = "" }, false);

    try std.testing.expectEqual(@as(usize, 7), g_entry_count);
    try std.testing.expectEqual(@as(?usize, 3), g_selected);
    try std.testing.expectEqual(@as(f32, 42), g_scroll_offset);
    try std.testing.expectEqual(true, g_focused);
    try std.testing.expectEqual(@as(u64, 99), g_async_context_id);
}

fn setFlatEntryPathForTest(idx: usize, path: []const u8) void {
    @memcpy(g_entries[idx].path_buf[0..path.len], path);
    g_entries[idx].path_len = @intCast(path.len);
}

test "file_explorer: refresh restore re-selects entry by path" {
    const saved_entry_count = g_entry_count;
    const saved_selected = g_selected;
    const saved_scroll = g_scroll_offset;
    const saved_pending = g_refresh_restore_pending;
    const saved_keep_len = g_refresh_keep_path_len;
    const saved_keep_scroll = g_refresh_keep_scroll;
    const saved_transfer_status = g_transfer_status;
    const saved_transfer_msg_len = g_transfer_msg_len;
    const saved_transfer_time = g_transfer_time;
    defer {
        g_entry_count = saved_entry_count;
        g_selected = saved_selected;
        g_scroll_offset = saved_scroll;
        g_refresh_restore_pending = saved_pending;
        g_refresh_keep_path_len = saved_keep_len;
        g_refresh_keep_scroll = saved_keep_scroll;
        g_transfer_status = saved_transfer_status;
        g_transfer_msg_len = saved_transfer_msg_len;
        g_transfer_time = saved_transfer_time;
    }

    g_entry_count = 3;
    setFlatEntryPathForTest(0, "a.txt");
    setFlatEntryPathForTest(1, "b.txt");
    setFlatEntryPathForTest(2, "c.txt");
    g_selected = null;
    g_scroll_offset = 0;

    g_refresh_restore_pending = true;
    g_refresh_keep_scroll = 0;
    @memcpy(g_refresh_keep_path[0..5], "b.txt");
    g_refresh_keep_path_len = 5;

    applyRefreshRestore();

    try std.testing.expectEqual(@as(?usize, 1), g_selected);
    try std.testing.expectEqual(false, g_refresh_restore_pending);
}

test "file_explorer: refresh restore clears selection when path is gone" {
    const saved_entry_count = g_entry_count;
    const saved_selected = g_selected;
    const saved_scroll = g_scroll_offset;
    const saved_pending = g_refresh_restore_pending;
    const saved_keep_len = g_refresh_keep_path_len;
    const saved_keep_scroll = g_refresh_keep_scroll;
    const saved_transfer_status = g_transfer_status;
    const saved_transfer_msg_len = g_transfer_msg_len;
    const saved_transfer_time = g_transfer_time;
    defer {
        g_entry_count = saved_entry_count;
        g_selected = saved_selected;
        g_scroll_offset = saved_scroll;
        g_refresh_restore_pending = saved_pending;
        g_refresh_keep_path_len = saved_keep_len;
        g_refresh_keep_scroll = saved_keep_scroll;
        g_transfer_status = saved_transfer_status;
        g_transfer_msg_len = saved_transfer_msg_len;
        g_transfer_time = saved_transfer_time;
    }

    g_entry_count = 2;
    setFlatEntryPathForTest(0, "x.txt");
    setFlatEntryPathForTest(1, "y.txt");
    g_selected = null;

    g_refresh_restore_pending = true;
    g_refresh_keep_scroll = 0;
    @memcpy(g_refresh_keep_path[0..8], "gone.txt");
    g_refresh_keep_path_len = 8;

    applyRefreshRestore();

    try std.testing.expectEqual(@as(?usize, null), g_selected);
}

test "file_explorer: terminal target equality checks ssh identity and cwd" {
    const conn_a: ssh_connection.SshConnection = .{
        .user_buf = [_]u8{ 'r', 'o', 'o', 't' } ++ [_]u8{0} ** 124,
        .user_len = 4,
        .host_buf = [_]u8{ 'h', 'o', 's', 't' } ++ [_]u8{0} ** 124,
        .host_len = 4,
        .port_buf = [_]u8{ '2', '2' } ++ [_]u8{0} ** 14,
        .port_len = 2,
        .password_buf = [_]u8{ 'p', 'w' } ++ [_]u8{0} ** 126,
        .password_len = 2,
        .password_auth = true,
        .legacy_algorithms = false,
    };
    const conn_b: ssh_connection.SshConnection = .{
        .user_buf = [_]u8{ 'r', 'o', 'o', 't' } ++ [_]u8{0} ** 124,
        .user_len = 4,
        .host_buf = [_]u8{ 'h', 'o', 's', 't' } ++ [_]u8{0} ** 124,
        .host_len = 4,
        .port_buf = [_]u8{ '2', '2' } ++ [_]u8{0} ** 14,
        .port_len = 2,
        .password_buf = [_]u8{ 'p', 'x' } ++ [_]u8{0} ** 126,
        .password_len = 2,
        .password_auth = true,
        .legacy_algorithms = false,
    };
    const saved_panel_mode = g_panel_mode;
    const saved_mode = g_mode;
    const saved_has_ssh_conn = g_has_ssh_conn;
    const saved_ssh_conn = g_ssh_conn;
    const saved_root_len = g_root_path_len;
    defer {
        g_panel_mode = saved_panel_mode;
        g_mode = saved_mode;
        g_has_ssh_conn = saved_has_ssh_conn;
        g_ssh_conn = saved_ssh_conn;
        g_root_path_len = saved_root_len;
    }

    g_panel_mode = .files;
    g_mode = .remote;
    g_has_ssh_conn = true;
    g_ssh_conn = conn_a;
    copyRootPathOnly("/tmp");

    try std.testing.expect(terminalTargetMatchesCurrentState(.{ .remote = .{ .conn = &conn_a, .cwd = "/tmp" } }));
    try std.testing.expect(!terminalTargetMatchesCurrentState(.{ .remote = .{ .conn = &conn_a, .cwd = "/var/tmp" } }));
    try std.testing.expect(!terminalTargetMatchesCurrentState(.{ .remote = .{ .conn = &conn_b, .cwd = "/tmp" } }));
}

test "file_explorer: history session ids preserve full utf8 ids" {
    const allocator = std.testing.allocator;
    var store = agent_history.Store.init(allocator);
    defer store.deinit();

    const long_session_id =
        "会話-会話-会話-会話-会話-会話-会話-会話-会話-会話-会話-会話-会話-会話-会話";
    try store.upsertRecord(.{
        .session_id = long_session_id,
        .title = "Saved chat",
        .base_url = "https://api.example.com",
        .api_key = "secret",
        .model = "gpt-test",
        .system_prompt = "system",
        .thinking_enabled = true,
        .reasoning_effort = "high",
        .stream = false,
        .agent_enabled = true,
        .created_at = 1,
        .updated_at = 2,
        .messages = &.{},
    });

    syncAgentHistoryRows(&store);

    try std.testing.expectEqual(@as(usize, 1), g_history_row_count);
    try std.testing.expectEqualStrings(long_session_id, historySessionIdAt(0).?);
}

test "file_explorer: history sync keeps nearest selection after selected session is deleted" {
    const allocator = std.testing.allocator;
    var store = agent_history.Store.init(allocator);
    defer store.deinit();

    try store.upsertRecord(.{
        .session_id = "old",
        .title = "Old",
        .base_url = "https://api.example.com",
        .api_key = "secret",
        .model = "gpt-old",
        .system_prompt = "system",
        .thinking_enabled = true,
        .reasoning_effort = "high",
        .stream = false,
        .agent_enabled = true,
        .created_at = 1,
        .updated_at = 1,
        .messages = &.{},
    });
    try store.upsertRecord(.{
        .session_id = "new",
        .title = "New",
        .base_url = "https://api.example.com",
        .api_key = "secret",
        .model = "gpt-new",
        .system_prompt = "system",
        .thinking_enabled = true,
        .reasoning_effort = "high",
        .stream = false,
        .agent_enabled = true,
        .created_at = 2,
        .updated_at = 2,
        .messages = &.{},
    });

    syncAgentHistoryRows(&store);
    g_history_selected = 0;

    try std.testing.expect(store.deleteBySessionId("new"));
    syncAgentHistoryRows(&store);

    try std.testing.expectEqual(@as(?usize, 0), g_history_selected);
    try std.testing.expectEqualStrings("old", historySessionIdAt(0).?);
}

test "file_explorer: history row text keeps valid utf8 when truncated" {
    const allocator = std.testing.allocator;
    var store = agent_history.Store.init(allocator);
    defer store.deinit();

    const long_title = "界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界界";
    const long_model = "模模模模模模模模模模模模模模模模模模模模模模";
    try store.upsertRecord(.{
        .session_id = "session-1",
        .title = long_title,
        .base_url = "https://api.example.com",
        .api_key = "secret",
        .model = long_model,
        .system_prompt = "system",
        .thinking_enabled = true,
        .reasoning_effort = "high",
        .stream = false,
        .agent_enabled = true,
        .created_at = 1,
        .updated_at = 2,
        .messages = &.{},
    });

    syncAgentHistoryRows(&store);

    try std.testing.expectEqual(@as(usize, 1), g_history_row_count);
    try std.testing.expect(std.unicode.utf8ValidateSlice(g_history_rows[0].title_buf[0..g_history_rows[0].title_len]));
    try std.testing.expect(std.unicode.utf8ValidateSlice(g_history_rows[0].model_buf[0..g_history_rows[0].model_len]));
}

test "file_explorer: localFileSize returns null for a directory but size for a file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);
    try std.testing.expectEqual(@as(?u64, null), localFileSize(dir_path));

    try tmp.dir.writeFile(.{ .sub_path = "f.txt", .data = "hello" });
    const file_path = try tmp.dir.realpathAlloc(std.testing.allocator, "f.txt");
    defer std.testing.allocator.free(file_path);
    try std.testing.expectEqual(@as(?u64, 5), localFileSize(file_path));
}
