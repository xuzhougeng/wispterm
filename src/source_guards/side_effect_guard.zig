//! Side-effect ratchet. UI invalidation must converge on the effect boundary:
//! input/overlay/command handlers return a `UiEffect`, and `AppWindow.applyUiEffect`
//! is the one place that maps it onto the `g_force_rebuild` / `g_cells_valid`
//! dirty globals (plus `window_backend.postWakeup()`). This freezes the number
//! of DIRECT writes to those globals per monolith file at today's value; it may
//! only shrink. New handlers must return an effect, not poke the globals.
//!
//! `input/dirty_guard.zig` already locks the converted regions of `input.zig`
//! function-by-function; this is the whole-file backstop across all four hubs.
//! See AGENTS.md (the render-gate Hard Rule) and docs/decoupling-guide.md.

const std = @import("std");
const scan = @import("scan.zig");

const Frozen = struct {
    name: []const u8,
    source: []const u8,
    /// Frozen at the current count; the ratchet may only ratchet DOWN.
    ceiling: usize,
};

// Ratchet ceilings for watched files (AppWindow 45, input 81, overlays 0,
// assistant/conversation/session.zig 0). Lower a ceiling only when direct
// writes are removed.
const monoliths = [_]Frozen{
    .{ .name = "AppWindow.zig", .source = @embedFile("../AppWindow.zig"), .ceiling = 45 },
    .{ .name = "input.zig", .source = @embedFile("../input.zig"), .ceiling = 81 },
    .{ .name = "renderer/overlays.zig", .source = @embedFile("../renderer/overlays.zig"), .ceiling = 0 },
    .{ .name = "assistant/conversation/session.zig", .source = @embedFile("../assistant/conversation/session.zig"), .ceiling = 0 },
};

fn directWriteCount(source: []const u8) usize {
    return scan.countOccurrences(source, "g_force_rebuild = ") +
        scan.countOccurrences(source, "g_cells_valid = ");
}

test "direct dirty-global writes in monolith files only shrink" {
    var failed = false;
    for (monoliths) |m| {
        const count = directWriteCount(m.source);
        if (count > m.ceiling) {
            std.debug.print(
                "side_effect_guard: {s} has {d} direct dirty-global writes (frozen ceiling {d}). " ++
                    "Return a UiEffect and land it through AppWindow.applyUiEffect; do not raise the ceiling.\n",
                .{ m.name, count, m.ceiling },
            );
            failed = true;
        }
    }
    try std.testing.expect(!failed);
}
