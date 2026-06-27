//! Global-state ratchet. The four monolith UI files accreted ~190 top-level
//! `g_*` globals (state scattered across facades, hostile to isolation and to
//! future multi-window work). This freezes each file's count at today's value:
//! it may only shrink. New mutable UI state must land in an explicit state
//! struct (e.g. `appwindow/state.zig`) or a feature-owned module, never as a
//! fresh top-level global in one of these hubs. See docs/decoupling-guide.md.

const std = @import("std");
const scan = @import("scan.zig");

const global_prefixes = [_][]const u8{
    "var g_",
    "pub var g_",
    "threadlocal var g_",
    "pub threadlocal var g_",
};

const Frozen = struct {
    name: []const u8,
    source: []const u8,
    /// Frozen at the current count; the ratchet may only ratchet DOWN.
    ceiling: usize,
};

const monoliths = [_]Frozen{
    // Ceilings re-tightened to the current actual after the adoption passes.
    // input.zig dropped 73->55 via file-explorer action/query APIs;
    // overlays.zig dropped 47->39 by moving command-palette fields into
    // OverlayState. AppWindow (67) and assistant/conversation/session.zig (20)
    // are at their actual.
    .{ .name = "AppWindow.zig", .source = @embedFile("../AppWindow.zig"), .ceiling = 67 },
    .{ .name = "input.zig", .source = @embedFile("../input.zig"), .ceiling = 52 },
    .{ .name = "renderer/overlays.zig", .source = @embedFile("../renderer/overlays.zig"), .ceiling = 39 },
    .{ .name = "assistant/conversation/session.zig", .source = @embedFile("../assistant/conversation/session.zig"), .ceiling = 20 },
};

fn globalCount(source: []const u8) usize {
    return scan.countTopLevelDecls(source, &global_prefixes);
}

test "top-level g_* globals in monolith files only shrink" {
    var failed = false;
    for (monoliths) |m| {
        const count = globalCount(m.source);
        if (count > m.ceiling) {
            std.debug.print(
                "global_state_guard: {s} has {d} top-level g_* globals (frozen ceiling {d}). " ++
                    "Move new state into a state struct; do not raise the ceiling.\n",
                .{ m.name, count, m.ceiling },
            );
            failed = true;
        }
    }
    try std.testing.expect(!failed);
}
