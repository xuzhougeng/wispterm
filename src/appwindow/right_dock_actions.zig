//! Right-dock orchestration: applies `right_dock` state transitions to the
//! features the dock hosts (Copilot, File Explorer) and to the browser panel
//! that shares the right edge. Kept out of AppWindow so the integration file
//! only forwards; the pure state/layout rules live in `right_dock.zig`.

const std = @import("std");
const build_options = @import("build_options");
const tab = @import("tab.zig");
const right_dock = @import("right_dock.zig");
const copilot_sidebar = @import("copilot_sidebar.zig");
const file_explorer = @import("../file_explorer.zig");
const platform_window_state = @import("../platform/window_state.zig");
const browser_panel = if (build_options.webview)
    @import("../browser/panel.zig")
else
    @import("../browser/panel_stub.zig");

pub const Host = struct {
    copilot: copilot_sidebar.Host,
    /// Resync the explorer to the active tab (AppWindow's
    /// `syncVisibleFileExplorerForActiveTab`); `force` rescans.
    sync_explorer: *const fn (force: bool) void,
    /// Panel widths changed: resize the terminal grid and repaint.
    relayout: *const fn () void,
};

/// True when the active tab's dock is open on a panel the current placement
/// can show. Any tab kind can host the dock; Copilot shows an empty state
/// off terminal tabs.
pub fn visible() bool {
    const dock = tab.activeRightDock() orelse return false;
    return dock.open and right_dock.panelAvailable(right_dock.g_state.placement, dock.panel);
}

/// The panel the active tab's dock is showing, or null when it is closed.
pub fn activePanel() ?right_dock.Panel {
    if (!visible()) return null;
    const dock = tab.activeRightDock() orelse return null;
    return dock.panel;
}

/// Explorer visibility while it is docked: the active tab's dock shows Files.
/// Installed into `file_explorer` so the dock is the single source of truth.
pub fn filesShowing() bool {
    return activePanel() == .files;
}

/// Open the dock on `panel`, or close it when that panel is already showing.
/// Shared by the Copilot / File Explorer shortcuts and the titlebar button.
pub fn toggle(host: Host, panel: right_dock.Panel) void {
    if (!right_dock.panelAvailable(right_dock.g_state.placement, panel)) return;
    transition(host, struct {
        fn apply(dock: *right_dock.TabDock, p: right_dock.Panel) bool {
            return right_dock.toggle(dock, p);
        }
    }.apply, panel);
}

/// Select `panel` (tab-row click), opening the dock if needed.
pub fn select(host: Host, panel: right_dock.Panel) void {
    if (!right_dock.panelAvailable(right_dock.g_state.placement, panel)) return;
    transition(host, struct {
        fn apply(dock: *right_dock.TabDock, p: right_dock.Panel) bool {
            return right_dock.show(dock, p);
        }
    }.apply, panel);
}

/// Reopen the dock on the last selected panel (closed-state edge handle).
pub fn summon(host: Host) void {
    const dock = tab.activeRightDock() orelse return;
    const panel = if (right_dock.panelAvailable(right_dock.g_state.placement, dock.panel)) dock.panel else .copilot;
    select(host, panel);
}

/// Close the active tab's dock (header toggle, browser opening, Escape).
pub fn close(host: Host) void {
    transition(host, struct {
        fn apply(dock: *right_dock.TabDock, _: right_dock.Panel) bool {
            return right_dock.close(dock);
        }
    }.apply, .copilot);
}

/// Close the dock only when `panel` is showing.
pub fn hidePanel(host: Host, panel: right_dock.Panel) void {
    transition(host, struct {
        fn apply(dock: *right_dock.TabDock, p: right_dock.Panel) bool {
            return right_dock.hidePanel(dock, p);
        }
    }.apply, panel);
}

/// Apply a new `file-explorer-position` (startup and hot reload). Moving the
/// explorer closes it on both sides so it never shows twice or drifts.
pub fn applyPlacement(placement: right_dock.Placement) bool {
    const changed = right_dock.g_state.placement != placement;
    right_dock.g_state.placement = placement;
    file_explorer.setDockVisibilityQuery(if (placement == .right) &filesShowing else null);
    if (!changed) return false;
    file_explorer.close();
    for (0..tab.g_tab_count) |idx| {
        const t = tab.g_tabs[idx] orelse continue;
        _ = right_dock.hidePanel(&t.right_dock, .files);
        if (t.right_dock.panel == .files) t.right_dock.panel = .copilot;
    }
    return true;
}

/// Record a finished resize drag so the width survives restarts.
pub fn persistWidth(allocator: ?std.mem.Allocator) void {
    const alloc = allocator orelse return;
    platform_window_state.setRightDockWidth(alloc, @intFromFloat(@round(right_dock.g_state.width)));
}

/// Restore the remembered width at startup.
pub fn restoreWidth(allocator: ?std.mem.Allocator) void {
    const alloc = allocator orelse return;
    const w = platform_window_state.rightDockWidth(alloc) orelse return;
    right_dock.restoreWidth(@floatFromInt(w));
}

fn transition(
    host: Host,
    comptime apply: fn (*right_dock.TabDock, right_dock.Panel) bool,
    panel: right_dock.Panel,
) void {
    const dock = tab.activeRightDock() orelse return;
    const before = dock.*;
    if (!apply(dock, panel)) return;
    const after = dock.*;

    if (before.showing(.copilot) and !after.showing(.copilot)) host.copilot.blur_input();
    if (before.showing(.files) and !after.showing(.files)) file_explorer.blurAndCancelOp();
    // The browser/Jupyter webview shares the right edge; the dock and it are
    // mutually exclusive, exactly as Copilot and the browser were before.
    if (after.open and !before.open) browser_panel.close();

    if (after.showing(.files) and !before.showing(.files)) {
        host.copilot.blur_input();
        host.sync_explorer(true);
        file_explorer.focus();
    }
    if (after.showing(.copilot) and !before.showing(.copilot) and tab.isActiveTabTerminal()) {
        file_explorer.blurAndCancelOp();
        // Missing profile: the dock stays open and explains itself (empty
        // state); a missing API key opens the config dialog as before.
        if (copilot_sidebar.ensureActiveSessionConfigured(host.copilot)) |_| {
            host.copilot.focus_input();
        }
        if (host.copilot.allocator) |alloc| platform_window_state.setCopilotHintShown(alloc);
    }
    host.relayout();
}
