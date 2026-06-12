//! updateTerminalCells rebuild-gating unit tests. The split-pane render path
//! relies on this dirty check to skip snapshot+rebuild for panes whose content
//! did not change, so these tests pin the gate's behavior: steady state skips,
//! and focus changes / content changes rebuild. Follows the
//! kitty_graphics_unit.zig pattern (stack Surface with only the touched fields
//! initialized, headless — no GL calls on this path).
const std = @import("std");
const ghostty_vt = @import("ghostty-vt");
const Surface = @import("../Surface.zig");
const Renderer = @import("Renderer.zig");
const cell_renderer = @import("cell_renderer.zig");

fn initTestSurface(surface: *Surface, allocator: std.mem.Allocator) !void {
    surface.allocator = allocator;
    surface.terminal = try ghostty_vt.Terminal.init(allocator, .{ .cols = 10, .rows = 4 });
    surface.selection = .{};
}

test "updateTerminalCellsForSurface: steady state skips rebuild, focus change rebuilds" {
    const allocator = std.testing.allocator;
    var surface: Surface = undefined;
    try initTestSurface(&surface, allocator);
    defer surface.terminal.deinit(allocator);

    var rend = Renderer.init(&surface);
    defer rend.deinit();
    cell_renderer.g_current_render_surface = &surface;
    defer cell_renderer.g_current_render_surface = null;

    // First call snapshots (Renderer.init starts with force_rebuild).
    try std.testing.expect(cell_renderer.updateTerminalCellsForSurface(&rend, &surface.terminal, true));
    // Nothing changed: the gate must skip — this is what lets the split path
    // avoid a full snapshot+rebuild per pane per frame.
    try std.testing.expect(!cell_renderer.updateTerminalCellsForSurface(&rend, &surface.terminal, true));
    // Focus change must rebuild: the cursor cell's background depends on the
    // effective cursor style (block vs hollow).
    try std.testing.expect(cell_renderer.updateTerminalCellsForSurface(&rend, &surface.terminal, false));
    try std.testing.expect(!cell_renderer.updateTerminalCellsForSurface(&rend, &surface.terminal, false));
    try std.testing.expect(cell_renderer.updateTerminalCellsForSurface(&rend, &surface.terminal, true));
}

test "updateTerminalCellsForSurface: new terminal output rebuilds" {
    const allocator = std.testing.allocator;
    var surface: Surface = undefined;
    try initTestSurface(&surface, allocator);
    defer surface.terminal.deinit(allocator);

    var rend = Renderer.init(&surface);
    defer rend.deinit();
    cell_renderer.g_current_render_surface = &surface;
    defer cell_renderer.g_current_render_surface = null;

    _ = cell_renderer.updateTerminalCellsForSurface(&rend, &surface.terminal, true);
    try std.testing.expect(!cell_renderer.updateTerminalCellsForSurface(&rend, &surface.terminal, true));

    var handler = surface.terminal.vtHandler();
    defer handler.deinit();
    var stream = ghostty_vt.Stream(@TypeOf(handler)).initAlloc(
        surface.terminal.screens.active.alloc,
        handler,
    );
    defer stream.deinit();
    stream.nextSlice("hello");

    try std.testing.expect(cell_renderer.updateTerminalCellsForSurface(&rend, &surface.terminal, true));
    try std.testing.expect(!cell_renderer.updateTerminalCellsForSurface(&rend, &surface.terminal, true));
}
