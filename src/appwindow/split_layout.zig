//! Split layout computation for AppWindow.
//!
//! Computes pixel rectangles for each surface in a split tree, handles
//! hit-testing for split dividers, and provides surface-at-point lookup.

const std = @import("std");
const AppWindow = @import("../AppWindow.zig");
const tab = AppWindow.tab;
const input = AppWindow.input;
const overlays = AppWindow.overlays;
const font = AppWindow.font;
const gl_init = AppWindow.gpu.gl_init;
const Surface = @import("../Surface.zig");
const SplitTree = @import("../split_tree.zig");
const renderer = @import("../renderer.zig");
const preview_close_button = @import("../input/preview_close_button.zig");

const TabState = tab.TabState;
pub const MAX_SPLITS_PER_TAB = tab.MAX_SPLITS_PER_TAB;
const SPLIT_DIVIDER_WIDTH = tab.SPLIT_DIVIDER_WIDTH;
pub const DEFAULT_PADDING = tab.DEFAULT_PADDING;

/// Pixel rectangle for a split leaf, including computed terminal dimensions.
/// The leaf may be a terminal or a non-terminal pane (e.g. a preview); use
/// `surface()` to get the *Surface (null for non-terminal panes). `cols`/`rows`
/// are 0 for non-terminal panes.
pub const SplitRect = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    cols: u16,
    rows: u16,
    pane: SplitTree.Pane,
    handle: SplitTree.Node.Handle,

    /// The terminal surface for this rect, or null if it holds a non-terminal
    /// pane (e.g. a preview).
    pub fn surface(self: SplitRect) ?*Surface {
        return self.pane.surface();
    }
};

/// A leaf pane plus its handle at a given window point. Unlike `surfaceAtPoint`,
/// this also reports non-terminal panes (e.g. previews) so focus can target them.
pub const PaneHit = struct {
    pane: SplitTree.Pane,
    handle: SplitTree.Node.Handle,
};

/// Hit test result for split dividers
pub const DividerHit = struct {
    handle: SplitTree.Node.Handle,
    layout: SplitTree.Split.Layout,
};

/// Computed split rects for the active tab (updated each frame)
pub threadlocal var g_split_rects: [MAX_SPLITS_PER_TAB]SplitRect = undefined;
pub threadlocal var g_split_rect_count: usize = 0;

/// Clear cached split rectangles after a split tree mutation.
pub fn invalidateCachedRects() void {
    g_split_rect_count = 0;
}

/// Returns true if a cached split rect still points at the active tab's tree.
pub fn cachedRectIsLive(rect: SplitRect) bool {
    const active_tab = tab.activeTab() orelse return false;
    if (rect.handle.idx() >= active_tab.tree.nodes.len) return false;
    return switch (active_tab.tree.nodes[rect.handle.idx()]) {
        .leaf => |pane| std.meta.eql(pane, rect.pane),
        .split => false,
    };
}

/// The lone visible leaf's terminal surface, or null when the active layout is
/// not exactly one terminal pane (several panes, or a single non-terminal pane
/// such as a preview). The render paths use this to gate the simple
/// single-surface fast path; preview-only layouts must take the generic
/// pane-dispatching path so they still paint.
pub fn soleTerminalSurface() ?*Surface {
    if (g_split_rect_count != 1) return null;
    return g_split_rects[0].surface();
}

/// Find the terminal surface under a given point (window coordinates).
/// Returns null if no terminal surface is found at that position (non-terminal
/// panes such as previews are skipped).
pub fn surfaceAtPoint(x: i32, y: i32) ?*Surface {
    for (0..g_split_rect_count) |i| {
        const rect = g_split_rects[i];
        if (!cachedRectIsLive(rect)) continue;
        if (x >= rect.x and x < rect.x + rect.width and
            y >= rect.y and y < rect.y + rect.height)
        {
            if (rect.pane.surface()) |s| return s;
        }
    }
    return null;
}

/// Find the leaf pane (terminal OR non-terminal) under a given point.
/// Returns null if the point is not inside any live leaf rect.
pub fn paneAtPoint(x: i32, y: i32) ?PaneHit {
    for (0..g_split_rect_count) |i| {
        const r = g_split_rects[i];
        if (!cachedRectIsLive(r)) continue;
        if (x >= r.x and x < r.x + r.width and y >= r.y and y < r.y + r.height)
            return .{ .pane = r.pane, .handle = r.handle };
    }
    return null;
}

/// If (x, y) lands on a preview pane's top-right close (×) button, return that
/// preview's handle; null otherwise. Mirrors the button geometry the preview
/// renderer draws (shared via preview_close_button), so the clickable box and
/// the drawn box stay in sync. Only live preview leaves are considered.
pub fn previewCloseButtonAtPoint(x: i32, y: i32) ?SplitTree.Node.Handle {
    const xf: f32 = @floatFromInt(x);
    const yf: f32 = @floatFromInt(y);
    for (0..g_split_rect_count) |i| {
        const r = g_split_rects[i];
        if (!cachedRectIsLive(r)) continue;
        switch (r.pane) {
            .preview => {
                if (preview_close_button.contains(
                    @floatFromInt(r.x),
                    @floatFromInt(r.y),
                    @floatFromInt(r.width),
                    xf,
                    yf,
                )) return r.handle;
            },
            .terminal => {},
        }
    }
    return null;
}

/// Check if a point is over a split divider.
/// Returns the split node handle and layout if found, null otherwise.
pub fn hitTestDivider(x: i32, y: i32) ?DividerHit {
    const active_tab = tab.activeTab() orelse return null;
    if (active_tab.tree.isEmpty() or !active_tab.tree.isSplit()) return null;

    const allocator = AppWindow.g_allocator orelse return null;
    var spatial = active_tab.tree.spatial(allocator) catch return null;
    defer spatial.deinit(allocator);

    // Get content area dimensions
    const win = AppWindow.g_window orelse return null;
    const fb = win.getFramebufferSize();
    const left_panels_w = AppWindow.leftPanelsWidth();
    const right_panels_w = AppWindow.rightPanelsWidthForWindow(fb.width);
    const content_x: f32 = left_panels_w + @as(f32, @floatFromInt(DEFAULT_PADDING));
    const content_y = AppWindow.currentTitlebarHeight();
    const content_w: f32 = @as(f32, @floatFromInt(fb.width)) - left_panels_w - right_panels_w - @as(f32, @floatFromInt(2 * DEFAULT_PADDING));
    const content_h: f32 = @as(f32, @floatFromInt(fb.height)) - content_y - @as(f32, @floatFromInt(DEFAULT_PADDING));

    const xf: f32 = @floatFromInt(x);
    const yf: f32 = @floatFromInt(y);
    const half_hit = input.SPLIT_DIVIDER_HIT_WIDTH / 2;

    // Check each split node for divider hit
    for (active_tab.tree.nodes, 0..) |node, i| {
        switch (node) {
            .split => |s| {
                const handle: SplitTree.Node.Handle = @enumFromInt(i);
                const slot = spatial.slots[i];

                // Convert normalized coords to pixels
                const slot_x = content_x + @as(f32, @floatCast(slot.x)) * content_w;
                const slot_y = content_y + @as(f32, @floatCast(slot.y)) * content_h;
                const slot_w = @as(f32, @floatCast(slot.width)) * content_w;
                const slot_h = @as(f32, @floatCast(slot.height)) * content_h;

                switch (s.layout) {
                    .horizontal => {
                        // Vertical divider line at ratio position
                        const div_x = slot_x + slot_w * @as(f32, @floatCast(s.ratio));
                        if (xf >= div_x - half_hit and xf <= div_x + half_hit and
                            yf >= slot_y and yf <= slot_y + slot_h)
                        {
                            return .{ .handle = handle, .layout = .horizontal };
                        }
                    },
                    .vertical => {
                        // Horizontal divider line at ratio position
                        const div_y = slot_y + slot_h * @as(f32, @floatCast(s.ratio));
                        if (yf >= div_y - half_hit and yf <= div_y + half_hit and
                            xf >= slot_x and xf <= slot_x + slot_w)
                        {
                            return .{ .handle = handle, .layout = .vertical };
                        }
                    },
                }
            },
            .leaf => {},
        }
    }

    return null;
}

/// Compute split layout for a tab, returning pixel rects for each surface.
/// Each surface is resized to fit its allocated area with proper padding.
/// Returns the number of surfaces (0 if tree is empty).
pub fn computeSplitLayout(
    active_tab: *const TabState,
    content_x: i32,
    content_y: i32,
    content_w: i32,
    content_h: i32,
    cw: f32, // font.cell_width
    ch: f32, // font.cell_height
) usize {
    g_split_rect_count = 0;
    if (active_tab.tree.isEmpty()) return 0;
    const safe_content_w = @max(content_w, 1);
    const safe_content_h = @max(content_h, 1);

    // Get spatial representation (normalized 0-1 coordinates)
    const allocator = AppWindow.g_allocator orelse return 0;
    var spatial = active_tab.tree.spatial(allocator) catch return 0;
    defer spatial.deinit(allocator);

    _ = cw;
    _ = ch;

    const resize_policy: Surface.ResizePolicy = if (AppWindow.consumeImmediateLayoutResize())
        .immediate
    else
        .coalesced;

    var count: usize = 0;
    var it = active_tab.tree.panes();
    while (it.next()) |entry| {
        if (count >= MAX_SPLITS_PER_TAB) break;

        const slot = spatial.slots[entry.handle.idx()];

        // Convert normalized coords to pixels
        const x_f: f32 = @as(f32, @floatCast(slot.x)) * @as(f32, @floatFromInt(safe_content_w));
        const y_f: f32 = @as(f32, @floatCast(slot.y)) * @as(f32, @floatFromInt(safe_content_h));
        const w_f: f32 = @as(f32, @floatCast(slot.width)) * @as(f32, @floatFromInt(safe_content_w));
        const h_f: f32 = @as(f32, @floatCast(slot.height)) * @as(f32, @floatFromInt(safe_content_h));

        // Apply divider insets (half-divider on each side adjacent to other splits)
        var px: i32 = content_x + @as(i32, @intFromFloat(x_f));
        var py: i32 = content_y + @as(i32, @intFromFloat(y_f));
        var pw: i32 = @as(i32, @intFromFloat(w_f));
        var ph: i32 = @as(i32, @intFromFloat(h_f));

        // Inset for dividers (only if not at edge)
        const half_div = @divTrunc(SPLIT_DIVIDER_WIDTH, 2);
        const at_left_edge = slot.x < 0.001;
        const at_right_edge = slot.x + slot.width >= 0.999;
        if (slot.x > 0.001) {
            px += half_div;
            pw -= half_div;
        }
        if (slot.x + slot.width < 0.999) {
            pw -= half_div;
        }
        if (slot.y > 0.001) {
            py += half_div;
            ph -= half_div;
        }
        if (slot.y + slot.height < 0.999) {
            ph -= half_div;
        }

        // Extend splits at left edge to window edge (consistent left margin)
        if (at_left_edge) {
            px -= @intCast(DEFAULT_PADDING);
            pw += @intCast(DEFAULT_PADDING);
        }

        // Extend splits at right edge to window edge (so scrollbar hugs window edge)
        if (at_right_edge) {
            pw += @intCast(DEFAULT_PADDING);
        }
        pw = @max(pw, 1);
        ph = @max(ph, 1);

        // Surface-only work: resize the terminal and track resize-overlay
        // bookkeeping. Non-terminal panes (e.g. previews) have no grid to size,
        // so we skip this entirely and store zero cols/rows for them.
        if (entry.pane.surface()) |surface| {
            // Set the surface screen size with padding.
            // The surface computes grid size and balanced padding internally.
            // Right padding must account for scrollbar width plus gap.
            const scrollbar_padding: u32 = @intFromFloat(overlays.SCROLLBAR_WIDTH + DEFAULT_PADDING);
            const explicit_padding = renderer.size.Padding{
                .top = DEFAULT_PADDING,
                .bottom = DEFAULT_PADDING,
                .left = DEFAULT_PADDING,
                .right = scrollbar_padding,
            };

            const resized = surface.setScreenSizeWithPolicy(
                if (pw > 0) @intCast(pw) else 1,
                if (ph > 0) @intCast(ph) else 1,
                font.cell_width,
                font.cell_height,
                explicit_padding,
                resize_policy,
            );

            if (resized) {
                AppWindow.g_force_rebuild = true;
                // Show resize overlay with new dimensions (but not during divider drag,
                // which has its own per-surface overlay logic)
                if (!input.g_divider_dragging) {
                    overlays.resizeOverlayShow(surface.size.grid.cols, surface.size.grid.rows);
                }
            }

            // Track per-surface size changes for divider drag overlay
            if (input.g_divider_dragging) {
                const cols = surface.size.grid.cols;
                const rows = surface.size.grid.rows;
                if (cols != surface.resize_overlay_last_cols or rows != surface.resize_overlay_last_rows) {
                    surface.resize_overlay_active = true;
                    surface.resize_overlay_last_cols = cols;
                    surface.resize_overlay_last_rows = rows;
                }
            }
        }

        g_split_rects[count] = .{
            .x = px,
            .y = py,
            .width = pw,
            .height = ph,
            .cols = if (entry.pane.surface()) |s| s.size.grid.cols else 0,
            .rows = if (entry.pane.surface()) |s| s.size.grid.rows else 0,
            .pane = entry.pane,
            .handle = entry.handle,
        };
        count += 1;
    }

    g_split_rect_count = count;
    return count;
}

test "split_layout: soleTerminalSurface only for a single terminal rect" {
    const PreviewPane = @import("../preview/pane.zig");
    const saved_count = g_split_rect_count;
    const saved_rect = g_split_rects[0];
    defer {
        g_split_rect_count = saved_count;
        g_split_rects[0] = saved_rect;
    }

    var surface: Surface = undefined;
    var preview: PreviewPane = undefined;
    const terminal_rect = SplitRect{
        .x = 0,
        .y = 0,
        .width = 100,
        .height = 100,
        .cols = 80,
        .rows = 24,
        .pane = .{ .terminal = &surface },
        .handle = .root,
    };
    const preview_rect = SplitRect{
        .x = 0,
        .y = 0,
        .width = 100,
        .height = 100,
        .cols = 0,
        .rows = 0,
        .pane = .{ .preview = &preview },
        .handle = .root,
    };

    // No rects → null.
    g_split_rect_count = 0;
    try std.testing.expect(soleTerminalSurface() == null);

    // One terminal rect → its surface.
    g_split_rects[0] = terminal_rect;
    g_split_rect_count = 1;
    try std.testing.expectEqual(@as(?*Surface, &surface), soleTerminalSurface());

    // One preview rect → null (preview-only layouts must take the generic path).
    g_split_rects[0] = preview_rect;
    try std.testing.expect(soleTerminalSurface() == null);

    // Multiple rects → null even if the first is a terminal.
    g_split_rects[0] = terminal_rect;
    g_split_rect_count = 2;
    try std.testing.expect(soleTerminalSurface() == null);
}
