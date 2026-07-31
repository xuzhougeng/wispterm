//! Copilot sidebar orchestration for AppWindow.

const std = @import("std");
const build_options = @import("build_options");
const ai_chat = @import("../assistant/conversation/session.zig");
const agent_history = @import("../agent/history.zig");
const agent_history_store = @import("../agent/history_store.zig");
const tab = @import("tab.zig");
const surface_snapshots = @import("surface_snapshots.zig");
const sidebar_panel = @import("../assistant/sidebar/panel.zig");
const picker = @import("../assistant/sidebar/picker.zig");
const platform_window_state = @import("../platform/window_state.zig");
const browser_panel = if (build_options.webview)
    @import("../browser/panel.zig")
else
    @import("../browser/panel_stub.zig");

pub const Host = struct {
    allocator: ?std.mem.Allocator,
    history_store: *?*agent_history_store.MetaStore,
    history_mutex: *std.Thread.Mutex,
    make_session: *const fn () ?*ai_chat.Session,
    open_api_config: *const fn (?*ai_chat.Session) void,
    focus_input: *const fn () void,
    blur_input: *const fn () void,
    mark_dirty: *const fn () void,
    mark_history_dirty_locked: *const fn () void,
    reopen_session: *const fn ([]const u8) ?*ai_chat.Session,
};

pub fn visible() bool {
    return tab.activeCopilotVisible();
}

pub fn hide(host: Host) void {
    if (!tab.setActiveCopilotVisible(false)) return;
    host.blur_input();
    host.mark_dirty();
}

pub fn width(window_width: i32, left_panels_width: f32) f32 {
    if (!visible()) return 0;
    return sidebar_panel.panelWidthForWindow(window_width, left_panels_width, 0);
}

pub fn activeSessionForInput() ?*ai_chat.Session {
    if (!visible()) return null;
    const t = tab.activeTab() orelse return null;
    return t.copilot_session;
}

pub fn ensureActiveSession(host: Host) ?*ai_chat.Session {
    const session = tab.activeCopilotSession(host.make_session) orelse return null;
    const context_surface_id = surface_snapshots.agentContextSurfaceId();
    if (context_surface_id.len > 0) session.setBoundSurface(context_surface_id);
    return session;
}

pub fn ensureActiveSessionConfigured(host: Host) ?*ai_chat.Session {
    const session = ensureActiveSession(host) orelse {
        _ = tab.setActiveCopilotVisible(false);
        host.blur_input();
        host.open_api_config(null);
        return null;
    };
    if (session.missingApiKey()) {
        host.open_api_config(session);
        return null;
    }
    return session;
}

pub fn openPicker(host: Host) void {
    refreshPickerRows(host);
}

pub fn refreshPickerRows(host: Host) void {
    const allocator = host.allocator orelse return;
    var empty_rows = [_]agent_history.Row{};
    host.history_mutex.lock();
    const rows: []agent_history.Row = blk: {
        defer host.history_mutex.unlock();
        const store = host.history_store.* orelse break :blk empty_rows[0..];
        break :blk store.buildCopilotRows(allocator) catch empty_rows[0..];
    };
    defer if (rows.len > 0) agent_history.freeRows(allocator, rows);

    var picker_rows: [picker.MAX_ROWS]picker.Row = undefined;
    const n = @min(rows.len, picker.MAX_ROWS);
    for (0..n) |i| picker_rows[i] = .{
        .session_id = rows[i].session_id,
        .title = rows[i].title,
        .updated_at = rows[i].updated_at,
    };
    picker.show(picker_rows[0..n]);
}

pub fn loadConversationById(host: Host, session_id: []const u8) void {
    if (tab.switchToCopilotTabBySessionId(session_id)) {
        browser_panel.close();
        _ = tab.setActiveCopilotVisible(true);
        host.focus_input();
        host.mark_dirty();
        return;
    }
    if (!tab.isActiveTabTerminal()) return;
    const t = tab.activeTab() orelse return;
    const session = host.reopen_session(session_id) orelse return;
    if (t.copilot_session) |old| old.deinit();
    t.copilot_session = session;
    browser_panel.close();
    _ = tab.setActiveCopilotVisible(true);
    host.focus_input();
    host.mark_dirty();
}

pub fn deleteConversationById(host: Host, session_id: []const u8) void {
    host.history_mutex.lock();
    defer host.history_mutex.unlock();
    const store = host.history_store.* orelse return;
    if (store.deleteBySessionId(session_id)) host.mark_history_dirty_locked();
}

pub fn newConversation(host: Host) void {
    if (!tab.isActiveTabTerminal()) return;
    const t = tab.activeTab() orelse return;
    if (t.copilot_session) |old| {
        old.deinit();
        t.copilot_session = null;
    }
    browser_panel.close();
    _ = tab.setActiveCopilotVisible(true);
    _ = ensureActiveSessionConfigured(host) orelse {
        host.mark_dirty();
        return;
    };
    host.focus_input();
    host.mark_dirty();
}

pub fn toggle(host: Host) void {
    if (!tab.isActiveTabTerminal()) return;
    if (tab.activeCopilotVisible()) {
        _ = tab.setActiveCopilotVisible(false);
        host.blur_input();
        host.mark_dirty();
        return;
    }
    browser_panel.close();
    _ = tab.setActiveCopilotVisible(true);
    _ = ensureActiveSessionConfigured(host) orelse {
        host.mark_dirty();
        return;
    };
    host.focus_input();
    if (host.allocator) |alloc| platform_window_state.setCopilotHintShown(alloc);
    host.mark_dirty();
}
