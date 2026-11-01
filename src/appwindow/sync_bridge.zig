//! Sync glue for the integration layer. Starts the sync worker with the
//! agent-history port, routes the Sync page's render/input, and, once per
//! window loop iteration, reloads what a sync rewrote and toasts results.
//! AppWindow hands in what it owns (history store + lock, geometry, draw
//! callbacks); nothing here imports AppWindow.
const std = @import("std");
const agent_history = @import("../agent/history.zig");
const agent_history_store = @import("../agent/history_store.zig");
const ai_profile_store = @import("../assistant/profile/store.zig");
const assistant_profiles = @import("../renderer/overlays/assistant_profiles.zig");
const credential_page = @import("../credential/page.zig");
const input_key = @import("../input/key.zig");
const overlays = @import("../renderer/overlays.zig");
const ssh_profile_store = @import("../ssh/profile_store.zig");
const ssh_profiles = @import("../renderer/overlays/ssh_profiles.zig");
const sync_kinds = @import("../sync/kinds.zig");
const sync_page = @import("../sync/page.zig");
const sync_renderer = @import("../renderer/sync_page_renderer.zig");
const sync_service = @import("../sync/service.zig");
const sync_settings = @import("../sync/settings.zig");
const window_backend = @import("../platform/window_backend.zig");

/// The process-wide agent-history store as AppWindow owns it.
pub const HistoryHost = struct {
    store: *?*agent_history_store.MetaStore,
    mutex: *std.Thread.Mutex,
    /// Called with `mutex` held after a change: schedules the flush and
    /// bumps the rows revision so history lists refresh.
    mark_dirty: *const fn () void,
};

/// Set once by the first window, read by the sync worker thread.
var history_host: ?HistoryHost = null;

pub fn startService(allocator: std.mem.Allocator, history: HistoryHost) void {
    if (history_host == null) history_host = history;
    sync_service.start(allocator, .{
        .history = .{ .list = historyList, .exportRecord = historyExport, .importRecord = historyImport, .delete = historyDelete },
        .ssh_header = ssh_profile_store.SSH_PROFILES_HEADER,
        .ai_header = ai_profile_store.AI_PROFILES_HEADER,
        .ssh_cap = ssh_profiles.SSH_PROFILE_MAX,
        .ai_cap = assistant_profiles.AI_PROFILE_MAX,
        .wake = window_backend.postWakeup,
    });
}

fn historyList(_: ?*anyopaque, arena: std.mem.Allocator) anyerror!?[]sync_kinds.HistoryMeta {
    const host = history_host orelse return null;
    host.mutex.lock();
    defer host.mutex.unlock();
    const store = host.store.* orelse return null;
    const out = try arena.alloc(sync_kinds.HistoryMeta, store.entries.items.len);
    for (store.entries.items, out) |entry, *meta| {
        meta.* = .{ .session_id = try arena.dupe(u8, entry.session_id), .updated_at = entry.updated_at };
    }
    return out;
}

fn historyExport(_: ?*anyopaque, arena: std.mem.Allocator, session_id: []const u8) anyerror!?[]const u8 {
    const host = history_host orelse return null;
    host.mutex.lock();
    defer host.mutex.unlock();
    const store = host.store.* orelse return null;
    const record = (try store.cloneRecordBySessionId(arena, session_id)) orelse return null;
    return try agent_history.recordToJson(arena, record);
}

fn historyImport(_: ?*anyopaque, arena: std.mem.Allocator, json: []const u8) anyerror!i64 {
    const record = try agent_history.recordFromJson(arena, json);
    const host = history_host orelse return error.HistoryUnavailable;
    host.mutex.lock();
    defer host.mutex.unlock();
    const store = host.store.* orelse return error.HistoryUnavailable;
    try store.upsertRecord(record);
    host.mark_dirty();
    return record.updated_at;
}

fn historyDelete(_: ?*anyopaque, session_id: []const u8) void {
    const host = history_host orelse return;
    host.mutex.lock();
    defer host.mutex.unlock();
    const store = host.store.* orelse return;
    if (store.deleteBySessionId(session_id)) host.mark_dirty();
}

// ---------------------------------------------------------------------------
// Sync page
// ---------------------------------------------------------------------------

pub const Frame = struct {
    window_height: f32,
    top_offset: f32,
    content_x: f32,
    content_width: f32,
    cell_h: f32,

    fn geometry(self: Frame) sync_renderer.Geometry {
        return sync_renderer.compute(sync_page.state(), self.window_height, self.top_offset, self.content_x, self.content_width, self.cell_h);
    }
};

pub fn openPage(allocator: std.mem.Allocator) void {
    const dir = sync_settings.defaultDir(allocator) catch return;
    defer allocator.free(dir);
    sync_page.state().open(allocator, dir);
}

pub fn render(draw: sync_renderer.DrawContext, frame: Frame) void {
    const view: sync_renderer.View = .{
        .status = sync_service.snapshot(),
        .passphrase_pending = sync_service.passphrasePending(),
        .now_ms = std.time.milliTimestamp(),
    };
    sync_renderer.render(draw, sync_page.state(), view, frame.geometry(), frame.window_height);
}

pub fn handleKey(ev: input_key.KeyEvent) void {
    sync_page.state().handleKey(ev);
}

pub fn paste(text: []const u8) bool {
    return sync_page.state().paste(text);
}

pub fn mousePress(frame: Frame, x: f32, y: f32) bool {
    const state = sync_page.state();
    switch (sync_renderer.hitTest(frame.geometry(), x, y)) {
        .none => return false,
        .section => |index| state.clickSection(index),
        .row => |index| state.clickRow(index),
    }
    return true;
}

pub fn mouseWheel(frame: Frame, x: f32, delta: i32) void {
    sync_page.state().scroll(if (delta > 0) -1 else 1, sync_renderer.overRail(frame.geometry(), x));
}

pub fn didDeactivate() void {
    sync_page.state().didDeactivate();
}

// ---------------------------------------------------------------------------
// Per-window follow-up after a sync
// ---------------------------------------------------------------------------

const Seen = struct {
    primed: bool = false,
    status: sync_service.Status = .{},
    data: [std.enums.values(sync_settings.Kind).len]u64 = @splat(0),
};

/// Per window thread, like the pages themselves.
threadlocal var seen: Seen = .{};

/// Reload this window's copies of data a sync rewrote, refresh the Sync page,
/// and toast a finished run. Returns whether the window should repaint.
pub fn poll() bool {
    const status = sync_service.snapshot();
    if (!seen.primed) {
        // A new window does not replay toasts for runs before it opened.
        seen.primed = true;
        seen.status = status;
        for (std.enums.values(sync_settings.Kind), 0..) |kind, i| seen.data[i] = sync_service.dataRevision(kind);
        return false;
    }
    var repaint = false;
    if (status.revision != seen.status.revision) {
        const notice = sync_service.noticeFor(seen.status, status);
        if (notice != .none) {
            var buf: [256]u8 = undefined;
            overlays.showStatusToast(sync_renderer.noticeText(notice, status, &buf));
        }
        seen.status = status;
        // The worker may have stored a derived key in settings.json.
        sync_page.state().reload();
        repaint = true;
    }
    for (std.enums.values(sync_settings.Kind), 0..) |kind, i| {
        const rev = sync_service.dataRevision(kind);
        if (rev == seen.data[i]) continue;
        const done = switch (kind) {
            .passwords => blk: {
                credential_page.state().refreshIfChanged();
                break :blk true;
            },
            .ssh_hosts => overlays.reloadProfileCachesAfterSync(true, false),
            .ai_profiles => overlays.reloadProfileCachesAfterSync(false, true),
            // The store itself was updated; mark_dirty refreshed the lists.
            .history => true,
        };
        if (done) {
            seen.data[i] = rev;
            repaint = true;
        }
    }
    return repaint;
}
