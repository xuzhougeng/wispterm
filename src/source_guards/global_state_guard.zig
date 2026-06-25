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
    .{ .name = "AppWindow.zig", .source = @embedFile("../AppWindow.zig"), .ceiling = 66 },
    .{ .name = "input.zig", .source = @embedFile("../input.zig"), .ceiling = 55 },
    .{ .name = "renderer/overlays.zig", .source = @embedFile("../renderer/overlays.zig"), .ceiling = 48 },
    .{ .name = "ai_chat.zig", .source = @embedFile("../ai_chat.zig"), .ceiling = 20 },
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

test "AppWindow does not mirror ssh legacy config as a global" {
    try std.testing.expect(std.mem.indexOf(u8, monoliths[0].source, "g_ssh_legacy_algorithms") == null);
    try std.testing.expect(std.mem.indexOf(u8, @embedFile("../appwindow/tab.zig"), "g_ssh_legacy_algorithms") == null);
}
