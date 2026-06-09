//! State for the right-side Markdown/text/image preview panel.
//! Content state is now owned by a single PreviewPane instance (g_dock).
//! Dock-geometry state (width, visibility, tab ownership) lives here unchanged.

const std = @import("std");
const markdown_preview = @import("markdown_preview.zig");
const tab = @import("appwindow/tab.zig");
const active_tab_state = @import("appwindow/active_tab.zig");
const PreviewPane = @import("preview_pane.zig");

pub const DEFAULT_WIDTH: f32 = 440;
pub const MIN_WIDTH: f32 = 280;
pub const MAX_WIDTH: f32 = 1800;
pub const MIN_CONTENT_WIDTH: f32 = 180;
pub const RESIZE_HIT_WIDTH: f32 = 16;

// Re-export types that callers depend on.
pub const PreviewSourceKind = PreviewPane.PreviewSourceKind;
pub const LoadStatus = PreviewPane.LoadStatus;

// Dock-geometry globals (unchanged).
pub threadlocal var g_visible: bool = false;
pub threadlocal var g_owner_tab: ?usize = null;
pub threadlocal var g_width: f32 = DEFAULT_WIDTH;

// Single PreviewPane instance backing the dock.
threadlocal var g_dock: ?*PreviewPane = null;

fn dock() *PreviewPane {
    if (g_dock == null) g_dock = PreviewPane.create(std.heap.page_allocator) catch @panic("preview dock alloc");
    return g_dock.?;
}

pub fn dockPane() *PreviewPane {
    return dock();
}

// ── Dock-geometry API (kept unchanged) ─────────────────────────────────────

pub fn width() f32 {
    return if (isVisibleForActiveTab()) g_width else 0;
}

pub fn isVisibleForActiveTab() bool {
    const owner = g_owner_tab orelse return false;
    return g_visible and owner == active_tab_state.g_active_tab;
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

pub fn maxWidthForWindow(window_width: f32) f32 {
    return @max(MIN_WIDTH, @min(MAX_WIDTH, window_width - MIN_CONTENT_WIDTH));
}

pub fn setWidth(w: f32, window_width: f32) bool {
    const next = @max(MIN_WIDTH, @min(maxWidthForWindow(window_width), w));
    if (next == g_width) return false;
    g_width = next;
    return true;
}

// ── Content accessors (delegating to PreviewPane) ───────────────────────────

pub fn kind() markdown_preview.Kind {
    return dock().kind;
}

pub fn loadStatus() LoadStatus {
    return dock().load_status;
}

pub fn scrollOffset() f32 {
    return dock().scroll_offset;
}

pub fn title() []const u8 {
    return dock().title();
}

pub fn path() []const u8 {
    return dock().path();
}

pub fn source() []const u8 {
    return dock().sourceText();
}

pub fn contentGeneration() u64 {
    return dock().contentGeneration();
}

pub fn imageZoom() f32 {
    return dock().imageZoom();
}

pub fn imagePanX() f32 {
    return dock().imagePanX();
}

pub fn imagePanY() f32 {
    return dock().imagePanY();
}

// ── Mutating API (delegating to PreviewPane) ────────────────────────────────

pub fn open(k: markdown_preview.Kind, preview_title: []const u8, preview_path: []const u8, source_text: []const u8) void {
    g_visible = true;
    g_owner_tab = active_tab_state.g_active_tab;
    dock().open(k, preview_title, preview_path, source_text);
}

pub fn beginAsyncLoad(k: markdown_preview.Kind, preview_title: []const u8, preview_path: []const u8, source_kind: PreviewSourceKind) bool {
    g_visible = true;
    g_owner_tab = active_tab_state.g_active_tab;
    return dock().beginAsyncLoad(k, preview_title, preview_path, source_kind);
}

pub fn tickAsync() bool {
    return if (g_dock) |d| d.tickAsync() else false;
}

pub fn scrollBy(delta: f32) void {
    dock().scrollBy(delta);
}

pub fn zoomImageBySteps(steps: usize, zoom_in: bool) bool {
    return dock().zoomImageBySteps(steps, zoom_in);
}

pub fn panImageBy(delta_x: f32, delta_y: f32) bool {
    return dock().panImageBy(delta_x, delta_y);
}

pub fn clampImagePan(view_w: f32, view_h: f32, draw_w: f32, draw_h: f32) void {
    dock().clampImagePan(view_w, view_h, draw_w, draw_h);
}

pub fn close() void {
    g_visible = false;
    g_owner_tab = null;
    if (g_dock) |d| d.open(.markdown, "", "", "");
}

pub fn deinit() void {
    if (g_dock) |d| {
        d.unref(std.heap.page_allocator);
        g_dock = null;
    }
}

// ── Tests ───────────────────────────────────────────────────────────────────

test "markdown_preview_panel: visible only on owning active tab" {
    const saved_visible = g_visible;
    const saved_owner = g_owner_tab;
    const saved_active_tab = active_tab_state.g_active_tab;
    defer {
        g_visible = saved_visible;
        g_owner_tab = saved_owner;
        active_tab_state.g_active_tab = saved_active_tab;
    }

    active_tab_state.g_active_tab = 0;
    open(.markdown, "README.md", "README.md", "# Title\n");

    try std.testing.expect(isVisibleForActiveTab());
    try std.testing.expectEqual(DEFAULT_WIDTH, width());

    active_tab_state.g_active_tab = 1;
    try std.testing.expect(!isVisibleForActiveTab());
    try std.testing.expectEqual(@as(f32, 0), width());

    active_tab_state.g_active_tab = 0;
    try std.testing.expect(isVisibleForActiveTab());
}
