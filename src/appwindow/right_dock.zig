//! Right dock: one switchable right-edge panel that hosts Copilot and the File
//! Explorer behind a tab row (plans/right_dock.md).
//!
//! Ownership is split the same way Ghostty splits its per-surface inspector
//! from window chrome: each tab owns whether its dock is open and which panel
//! is selected (`TabDock`, stored on `TabState`), while the window owns the
//! shared width and the `file-explorer-position` placement (`State`). One
//! width for every dock tab means switching tabs never resizes the terminal.
//!
//! This module is pure state + layout math (no tab/AppWindow/renderer imports)
//! so it runs in the fast test suite. Visibility gates ("only terminal tabs
//! host Copilot") are applied by the caller.

const std = @import("std");

pub const Panel = enum {
    copilot,
    files,

    pub fn label(self: Panel) []const u8 {
        return switch (self) {
            .copilot => "Copilot",
            .files => "Files",
        };
    }
};

/// Value of the `file-explorer-position` config key. Named after Ghostty's
/// `quick-terminal-position` / `gtk-tabs-location` enums.
pub const Placement = enum { left, right };

pub const DEFAULT_WIDTH: f32 = 480;
// Copilot's header (model, Agent mode, permission chip, status dot) needs this
// much room to stay legible, so it bounds the shared dock width.
pub const MIN_WIDTH: f32 = 380;
pub const MAX_WIDTH: f32 = 1200;
pub const MIN_CONTENT_WIDTH: f32 = 320;
pub const RESIZE_HIT_WIDTH: f32 = 12;
pub const HANDLE_W: f32 = 6;
pub const HANDLE_H: f32 = 56;

// Tab-row metrics in logical (96 DPI) pixels; `headerLayout` multiplies them
// by the UI scale so a 2x Retina display gets the same physical size.
pub const TAB_ROW_MIN_H: f32 = 34;
pub const TAB_ICON_W: f32 = 30;
pub const TAB_GAP: f32 = 4;
pub const TAB_ROW_PAD_X: f32 = 8;
pub const TAB_LABEL_PAD: f32 = 10;
pub const TOGGLE_W: f32 = 30;
pub const MIN_LABEL_W: f32 = 24;
pub const MAX_PANELS = std.meta.fields(Panel).len;

/// Per-tab dock state. Replaces the old `TabState.copilot_visible` flag:
/// "Copilot visible" is now `showing(.copilot)`.
pub const TabDock = struct {
    open: bool = false,
    panel: Panel = .copilot,

    pub fn showing(self: TabDock, panel: Panel) bool {
        return self.open and self.panel == panel;
    }

    /// Session files written before the dock store only `copilot_visible`.
    pub fn fromCopilotVisible(visible: bool) TabDock {
        return .{ .open = visible, .panel = .copilot };
    }
};

/// Open the dock on `panel`, or close it when `panel` is already showing.
/// Returns true when the dock state changed.
pub fn toggle(dock: *TabDock, panel: Panel) bool {
    if (dock.showing(panel)) return close(dock);
    return show(dock, panel);
}

/// Open the dock with `panel` selected. Returns true when anything changed.
pub fn show(dock: *TabDock, panel: Panel) bool {
    if (dock.showing(panel)) return false;
    dock.* = .{ .open = true, .panel = panel };
    return true;
}

/// Close the dock, keeping the selected panel so the next open restores it.
pub fn close(dock: *TabDock) bool {
    if (!dock.open) return false;
    dock.open = false;
    return true;
}

/// Close the dock only when `panel` is the one showing (used when a feature
/// hides itself, e.g. Copilot losing its API config).
pub fn hidePanel(dock: *TabDock, panel: Panel) bool {
    if (!dock.showing(panel)) return false;
    return close(dock);
}

pub fn panelAvailable(placement: Placement, panel: Panel) bool {
    return switch (panel) {
        .copilot => true,
        .files => placement == .right,
    };
}

/// Panels that get a tab in the dock header, in display order.
pub fn availablePanels(placement: Placement, buf: *[MAX_PANELS]Panel) []const Panel {
    var n: usize = 0;
    for ([_]Panel{ .copilot, .files }) |panel| {
        if (!panelAvailable(placement, panel)) continue;
        buf[n] = panel;
        n += 1;
    }
    return buf[0..n];
}

/// Window-level dock state: one shared width plus the explorer placement.
pub const State = struct {
    width: f32 = DEFAULT_WIDTH,
    placement: Placement = .right,
};

/// Pointer-interaction flags for the dock's resize edge. Lives here instead of
/// as more `input.zig` globals.
pub const Interaction = struct {
    resize_hover: bool = false,
    resize_dragging: bool = false,
    /// Tab-row target under the pointer; a change requests a repaint.
    header_hover: ?HeaderHit = null,
};

pub threadlocal var g_state: State = .{};
pub threadlocal var g_interaction: Interaction = .{};

pub fn explorerDocked() bool {
    return g_state.placement == .right;
}

pub fn maxWidthForWindow(available_width: f32) f32 {
    return @max(MIN_WIDTH, @min(MAX_WIDTH, available_width - MIN_CONTENT_WIDTH));
}

pub fn clampWidth(w: f32, available_width: f32) f32 {
    return @max(MIN_WIDTH, @min(maxWidthForWindow(available_width), w));
}

/// Set the shared dock width, clamped for `available_width` (window width
/// minus left panels). Returns true when the value changed.
pub fn setWidth(w: f32, available_width: f32) bool {
    const next = clampWidth(w, available_width);
    if (next == g_state.width) return false;
    g_state.width = next;
    return true;
}

/// Restore a persisted width without a window to clamp against yet; the
/// per-frame `panelWidthForWindow` clamp still applies.
pub fn restoreWidth(w: f32) void {
    if (!std.math.isFinite(w)) return;
    g_state.width = @max(MIN_WIDTH, @min(MAX_WIDTH, w));
}

/// Width the dock occupies in a window, leaving MIN_CONTENT_WIDTH for the
/// terminal. Pure math: callers gate on visibility.
pub fn panelWidthForWindow(window_width: i32, left_offset: f32, right_offset: f32) f32 {
    const win_w: f32 = @floatFromInt(window_width);
    const max_width = @max(MIN_WIDTH, @min(MAX_WIDTH, win_w - left_offset - right_offset - MIN_CONTENT_WIDTH));
    return @max(MIN_WIDTH, @min(g_state.width, max_width));
}

/// Integer pixel bounds, top-down (y grows downward from the window top).
pub const Bounds = struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,

    pub fn contains(self: Bounds, x: f64, y: f64) bool {
        return x >= @as(f64, @floatFromInt(self.left)) and x < @as(f64, @floatFromInt(self.right)) and
            y >= @as(f64, @floatFromInt(self.top)) and y < @as(f64, @floatFromInt(self.bottom));
    }

    pub fn width(self: Bounds) f32 {
        return @floatFromInt(@max(0, self.right - self.left));
    }
};

/// Whole dock (tab row + content), right-docked.
pub fn boundsForWindow(window_width: i32, window_height: i32, titlebar_height: f32, left_offset: f32, right_offset: f32) Bounds {
    const win_w: f32 = @floatFromInt(window_width);
    const win_h: f32 = @floatFromInt(window_height);
    const panel_w = panelWidthForWindow(window_width, left_offset, right_offset);
    const right = @max(0, win_w - right_offset);
    const left = @max(left_offset, right - panel_w);
    const top = @max(0, titlebar_height);
    const bottom = @max(top, win_h);
    return .{
        .left = @intFromFloat(@round(left)),
        .top = @intFromFloat(@round(top)),
        .right = @intFromFloat(@round(right)),
        .bottom = @intFromFloat(@round(bottom)),
    };
}

/// Framebuffer pixels per logical pixel (titlebar uses the same dpi / 96).
pub fn uiScaleForDpi(dpi: u32) f32 {
    if (dpi == 0) return 1;
    return @max(1.0, @as(f32, @floatFromInt(dpi)) / 96.0);
}

pub fn tabRowHeight(text_height: f32, scale: f32) f32 {
    return @max(TAB_ROW_MIN_H * scale, @round(text_height + 14 * scale));
}

/// The panel area below the tab row.
pub fn contentBounds(dock: Bounds, tab_row_h: f32) Bounds {
    const row: i32 = @intFromFloat(@round(@max(0, tab_row_h)));
    return .{
        .left = dock.left,
        .top = @min(dock.bottom, dock.top + row),
        .right = dock.right,
        .bottom = dock.bottom,
    };
}

/// True when (x, y) is on the dock's left (resize) edge.
pub fn resizeHandleHit(dock: Bounds, x: f64, y: f64) bool {
    if (y < @as(f64, @floatFromInt(dock.top)) or y >= @as(f64, @floatFromInt(dock.bottom))) return false;
    const edge: f64 = @floatFromInt(dock.left);
    const half: f64 = RESIZE_HIT_WIDTH / 2;
    return x >= edge - half and x <= edge + half;
}

/// Top-down float rect used by the header layout.
pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,

    pub fn contains(self: Rect, px: f64, py: f64) bool {
        return px >= self.x and px < self.x + self.w and py >= self.y and py < self.y + self.h;
    }
};

pub const TabSlot = struct {
    panel: Panel,
    rect: Rect,
    selected: bool,
    /// Selected tab expands into an icon + label pill; others are icon-only.
    show_label: bool,
    label_w: f32,
};

pub const HeaderLayout = struct {
    row: Rect,
    tabs: [MAX_PANELS]TabSlot = undefined,
    tab_count: usize = 0,
    toggle: Rect,
    /// Scaled width of the icon square at the start of every tab.
    icon_w: f32 = TAB_ICON_W,

    pub fn slots(self: *const HeaderLayout) []const TabSlot {
        return self.tabs[0..self.tab_count];
    }
};

pub const HeaderHit = union(enum) {
    tab: Panel,
    toggle,
};

/// Lay out the tab row: icon-only tabs from the left (the selected one grows
/// to icon + label when it fits), the open/close toggle at the far right.
/// `selected_label_w` is the measured label width of the selected panel (in
/// framebuffer pixels); `scale` converts the logical metrics above.
pub fn headerLayout(dock: Bounds, row_h: f32, panels: []const Panel, selected: Panel, selected_label_w: f32, scale: f32) HeaderLayout {
    const left: f32 = @floatFromInt(dock.left);
    const right: f32 = @floatFromInt(dock.right);
    const top: f32 = @floatFromInt(dock.top);
    const icon_w = TAB_ICON_W * scale;
    const gap = TAB_GAP * scale;
    const pad_x = TAB_ROW_PAD_X * scale;
    const label_pad = TAB_LABEL_PAD * scale;
    const toggle_w = TOGGLE_W * scale;
    const button_h = @max(0, @min(row_h - 6 * scale, icon_w));
    const button_y = top + @round((row_h - button_h) / 2);

    var layout: HeaderLayout = .{
        .row = .{ .x = left, .y = top, .w = @max(0, right - left), .h = row_h },
        .toggle = .{ .x = right - pad_x + 2 * scale - toggle_w, .y = button_y, .w = toggle_w, .h = button_h },
        .icon_w = icon_w,
    };

    // Space the tabs may use before the toggle.
    const tabs_right = layout.toggle.x - gap;
    var icon_only_w: f32 = 0;
    for (panels, 0..) |_, i| {
        if (i > 0) icon_only_w += gap;
        icon_only_w += icon_w;
    }
    const spare = tabs_right - (left + pad_x) - icon_only_w;
    const wanted_label = @max(0, selected_label_w) + label_pad;
    const label_room = @min(wanted_label, @max(0, spare));
    const show_label = label_room >= MIN_LABEL_W * scale;

    var x = left + pad_x;
    for (panels) |panel| {
        if (layout.tab_count >= MAX_PANELS) break;
        const is_selected = panel == selected;
        const label_w: f32 = if (is_selected and show_label) label_room else 0;
        const w = icon_w + label_w;
        layout.tabs[layout.tab_count] = .{
            .panel = panel,
            .rect = .{ .x = x, .y = button_y, .w = w, .h = button_h },
            .selected = is_selected,
            .show_label = is_selected and show_label,
            .label_w = @max(0, label_w - label_pad),
        };
        layout.tab_count += 1;
        x += w + gap;
    }
    return layout;
}

pub fn headerHitAt(layout: *const HeaderLayout, x: f64, y: f64) ?HeaderHit {
    if (!layout.row.contains(x, y)) return null;
    if (layout.toggle.contains(x, y)) return .toggle;
    for (layout.slots()) |slot| {
        if (slot.rect.contains(x, y)) return .{ .tab = slot.panel };
    }
    return null;
}

pub const HandleRect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    /// false when opening the dock would not fit (window too narrow); the
    /// caller suppresses the handle in that case.
    eligible: bool,
};

/// Closed-state summon-handle rect at the window's right edge, vertically
/// centered in the content area (top-down coords; `titlebar_h` is the inset).
pub fn closedHandleRect(window_w: f32, window_h: f32, titlebar_h: f32, left_offset: f32) HandleRect {
    const content_h = @max(0, window_h - titlebar_h);
    const y = titlebar_h + @max(0, (content_h - HANDLE_H) / 2);
    const x = window_w - HANDLE_W;
    const fits = (window_w - left_offset) >= (MIN_WIDTH + MIN_CONTENT_WIDTH);
    return .{ .x = x, .y = y, .w = HANDLE_W, .h = HANDLE_H, .eligible = fits };
}

/// One-line explanation shown when a dock tab has nothing to display.
pub const EmptyState = struct {
    title: []const u8,
    detail: []const u8,
};

pub const CopilotStatus = enum { ready, not_terminal_tab, no_profile };

pub fn copilotEmptyState(status: CopilotStatus) ?EmptyState {
    return switch (status) {
        .ready => null,
        .not_terminal_tab => .{
            .title = "Copilot runs beside terminal tabs.",
            .detail = "Switch to a terminal tab to chat.",
        },
        .no_profile => .{
            .title = "No Copilot profile configured.",
            .detail = "Open Settings > AI to add one.",
        },
    };
}

pub const FilesStatus = enum { ready, loading, no_root, empty_dir, no_history };

pub fn filesEmptyState(status: FilesStatus) ?EmptyState {
    return switch (status) {
        .ready, .loading => null,
        .no_root => .{
            .title = "No working directory yet.",
            .detail = "The shell has not reported one; cd somewhere or press Refresh.",
        },
        .empty_dir => .{
            .title = "This folder is empty.",
            .detail = "New files appear here; press Refresh after creating some.",
        },
        .no_history => .{
            .title = "No saved agent conversations yet.",
            .detail = "Finished AI chats are listed here.",
        },
    };
}

/// Pure classification of the explorer's current contents.
pub fn filesStatus(agent_history: bool, loading: bool, has_root: bool, row_count: usize) FilesStatus {
    if (agent_history) return if (row_count == 0) .no_history else .ready;
    if (row_count > 0) return .ready;
    if (loading) return .loading;
    if (!has_root) return .no_root;
    return .empty_dir;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "toggle opens on the requested panel and closes when it is showing" {
    var dock: TabDock = .{};
    try testing.expect(toggle(&dock, .files));
    try testing.expect(dock.showing(.files));
    // Toggling a different panel switches instead of closing.
    try testing.expect(toggle(&dock, .copilot));
    try testing.expect(dock.showing(.copilot));
    try testing.expect(!dock.showing(.files));
    try testing.expect(toggle(&dock, .copilot));
    try testing.expect(!dock.open);
    // Closing keeps the selection for the next open.
    try testing.expectEqual(Panel.copilot, dock.panel);
}

test "show, close and hidePanel report changes" {
    var dock: TabDock = .{};
    try testing.expect(!close(&dock));
    try testing.expect(show(&dock, .files));
    try testing.expect(!show(&dock, .files));
    try testing.expect(!hidePanel(&dock, .copilot));
    try testing.expect(dock.open);
    try testing.expect(hidePanel(&dock, .files));
    try testing.expect(!dock.open);
    try testing.expectEqual(Panel.files, dock.panel);
}

test "fromCopilotVisible restores legacy session state" {
    try testing.expect(TabDock.fromCopilotVisible(true).showing(.copilot));
    try testing.expect(!TabDock.fromCopilotVisible(false).open);
}

test "files tab only exists when the explorer is docked right" {
    var buf: [MAX_PANELS]Panel = undefined;
    const right = availablePanels(.right, &buf);
    try testing.expectEqual(@as(usize, 2), right.len);
    try testing.expectEqual(Panel.copilot, right[0]);
    try testing.expectEqual(Panel.files, right[1]);
    const left = availablePanels(.left, &buf);
    try testing.expectEqual(@as(usize, 1), left.len);
    try testing.expectEqual(Panel.copilot, left[0]);
    try testing.expect(!panelAvailable(.left, .files));
}

test "width clamps to the window and keeps terminal content room" {
    const saved = g_state;
    defer g_state = saved;
    g_state.width = 480;
    try testing.expectApproxEqAbs(@as(f32, 480), panelWidthForWindow(1600, 0, 0), 0.001);
    g_state.width = 1200;
    // 800 - 320 content = 480 available.
    try testing.expectApproxEqAbs(@as(f32, 480), panelWidthForWindow(800, 0, 0), 0.001);
    // Never below MIN_WIDTH even when the window is tiny.
    try testing.expectApproxEqAbs(MIN_WIDTH, panelWidthForWindow(300, 0, 0), 0.001);
}

test "setWidth clamps and reports change; restoreWidth sanitizes" {
    const saved = g_state;
    defer g_state = saved;
    g_state.width = DEFAULT_WIDTH;
    try testing.expect(setWidth(10_000, 1600));
    try testing.expectApproxEqAbs(maxWidthForWindow(1600), g_state.width, 0.001);
    try testing.expect(!setWidth(g_state.width, 1600));
    restoreWidth(50);
    try testing.expectApproxEqAbs(MIN_WIDTH, g_state.width, 0.001);
    restoreWidth(std.math.nan(f32));
    try testing.expectApproxEqAbs(MIN_WIDTH, g_state.width, 0.001);
}

test "dock bounds right-dock and content sits below the tab row" {
    const saved = g_state;
    defer g_state = saved;
    g_state.width = 480;
    const b = boundsForWindow(1600, 900, 30, 0, 0);
    try testing.expectEqual(@as(i32, 1120), b.left);
    try testing.expectEqual(@as(i32, 1600), b.right);
    try testing.expectEqual(@as(i32, 30), b.top);
    try testing.expectEqual(@as(i32, 900), b.bottom);
    const c = contentBounds(b, 34);
    try testing.expectEqual(@as(i32, 64), c.top);
    try testing.expectEqual(b.left, c.left);
    try testing.expectEqual(b.right, c.right);
    // An oversized row never inverts the content rect.
    try testing.expectEqual(b.bottom, contentBounds(b, 5000).top);

    const offset = boundsForWindow(1600, 900, 30, 200, 100);
    try testing.expectEqual(@as(i32, 1500), offset.right);
    try testing.expectEqual(@as(i32, 1020), offset.left);
}

test "resize handle straddles the dock's left edge" {
    const b: Bounds = .{ .left = 1000, .top = 30, .right = 1500, .bottom = 900 };
    try testing.expect(resizeHandleHit(b, 1000, 400));
    try testing.expect(resizeHandleHit(b, 1000 - RESIZE_HIT_WIDTH / 2, 400));
    try testing.expect(!resizeHandleHit(b, 1000 + RESIZE_HIT_WIDTH, 400));
    try testing.expect(!resizeHandleHit(b, 1000, 10)); // titlebar band
}

test "header: icon-only tabs, selected expands to icon + label, toggle far right" {
    const b: Bounds = .{ .left = 1000, .top = 30, .right = 1480, .bottom = 900 };
    const panels = [_]Panel{ .copilot, .files };
    const layout = headerLayout(b, 34, &panels, .files, 40, 1);
    try testing.expectEqual(@as(usize, 2), layout.tab_count);

    const copilot = layout.tabs[0];
    const files = layout.tabs[1];
    try testing.expect(!copilot.selected and !copilot.show_label);
    try testing.expectApproxEqAbs(TAB_ICON_W, copilot.rect.w, 0.001);
    try testing.expect(files.selected and files.show_label);
    try testing.expectApproxEqAbs(TAB_ICON_W + 40 + TAB_LABEL_PAD, files.rect.w, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 40), files.label_w, 0.001);
    try testing.expect(files.rect.x > copilot.rect.x + copilot.rect.w);

    // Toggle hugs the right edge and never overlaps a tab.
    try testing.expect(layout.toggle.x + layout.toggle.w <= 1480);
    try testing.expect(layout.toggle.x > files.rect.x + files.rect.w);
    // Buttons are vertically centered in the row.
    try testing.expectApproxEqAbs(layout.row.y + (34 - copilot.rect.h) / 2, copilot.rect.y, 1.0);
}

test "header: metrics scale with DPI" {
    const b: Bounds = .{ .left = 2000, .top = 60, .right = 2960, .bottom = 1800 };
    const panels = [_]Panel{ .copilot, .files };
    const s2 = uiScaleForDpi(192);
    try testing.expectApproxEqAbs(@as(f32, 2), s2, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1), uiScaleForDpi(72), 0.001);
    const row_h = tabRowHeight(26, s2);
    try testing.expectApproxEqAbs(TAB_ROW_MIN_H * 2, row_h, 0.001);
    const layout = headerLayout(b, row_h, &panels, .copilot, 80, s2);
    try testing.expectApproxEqAbs(TAB_ICON_W * 2, layout.tabs[1].rect.w, 0.001);
    try testing.expectApproxEqAbs(TAB_ICON_W * 2, layout.icon_w, 0.001);
    try testing.expectApproxEqAbs(TOGGLE_W * 2, layout.toggle.w, 0.001);
}

test "header: label is dropped when the dock is too narrow" {
    const b: Bounds = .{ .left = 0, .top = 0, .right = 120, .bottom = 400 };
    const panels = [_]Panel{ .copilot, .files };
    const layout = headerLayout(b, 32, &panels, .copilot, 200, 1);
    try testing.expect(!layout.tabs[0].show_label);
    try testing.expectApproxEqAbs(TAB_ICON_W, layout.tabs[0].rect.w, 0.001);
}

test "header hit-testing finds tabs and the toggle" {
    const b: Bounds = .{ .left = 1000, .top = 30, .right = 1480, .bottom = 900 };
    const panels = [_]Panel{ .copilot, .files };
    const layout = headerLayout(b, 34, &panels, .copilot, 50, 1);
    const files = layout.tabs[1].rect;
    try testing.expectEqual(HeaderHit{ .tab = .files }, headerHitAt(&layout, files.x + 2, files.y + 2).?);
    const t = layout.toggle;
    try testing.expectEqual(HeaderHit.toggle, headerHitAt(&layout, t.x + t.w / 2, t.y + t.h / 2).?);
    // Empty stretch of the row and the content area below hit nothing.
    try testing.expect(headerHitAt(&layout, t.x - 20, t.y + 2) == null);
    try testing.expect(headerHitAt(&layout, files.x + 2, 30 + 40) == null);
}

test "closed handle sits at the right edge and needs room to open" {
    const r = closedHandleRect(1600, 900, 30, 0);
    try testing.expect(r.eligible);
    try testing.expectApproxEqAbs(@as(f32, 1600 - HANDLE_W), r.x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 437), r.y, 0.001);
    try testing.expect(!closedHandleRect(600, 800, 30, 0).eligible);
    try testing.expect(closedHandleRect(700, 800, 30, 0).eligible);
}

test "each tab explains why it is empty" {
    try testing.expect(copilotEmptyState(.ready) == null);
    try testing.expect(copilotEmptyState(.not_terminal_tab).?.title.len > 0);
    try testing.expect(copilotEmptyState(.no_profile).?.detail.len > 0);
    try testing.expectEqual(FilesStatus.no_root, filesStatus(false, false, false, 0));
    try testing.expectEqual(FilesStatus.loading, filesStatus(false, true, true, 0));
    try testing.expectEqual(FilesStatus.empty_dir, filesStatus(false, false, true, 0));
    try testing.expectEqual(FilesStatus.ready, filesStatus(false, false, true, 3));
    try testing.expectEqual(FilesStatus.no_history, filesStatus(true, false, false, 0));
    try testing.expectEqual(FilesStatus.ready, filesStatus(true, false, false, 2));
    try testing.expect(filesEmptyState(.loading) == null);
    try testing.expect(filesEmptyState(.no_root).?.title.len > 0);
    try testing.expect(filesEmptyState(.empty_dir).?.title.len > 0);
    try testing.expect(filesEmptyState(.no_history).?.title.len > 0);
}
