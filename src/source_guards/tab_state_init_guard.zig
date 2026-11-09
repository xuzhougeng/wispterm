//! `TabState` construction guard. `allocator.create` returns undefined memory
//! (0xAA-filled in Debug), and assigning fields one at a time does NOT apply
//! the struct's declaration defaults — a field the site forgets stays garbage.
//! That is how tmux tabs got an undefined `right_dock` and center-session
//! pointers, and Skill Center / Port Forwarding tabs an undefined `tmux_owner`
//! (same class as the `Surface.agent_transcript` tab-close crash).
//!
//! Every `create(TabState)` must therefore be initialized with one whole-struct
//! literal (`t.* = .{ ... }`), so a newly added defaulted field is covered at
//! every site automatically. Ghostty builds its surfaces the same way.

const std = @import("std");

const sources = [_]struct { name: []const u8, text: []const u8 }{
    .{ .name = "appwindow/tab.zig", .text = @embedFile("../appwindow/tab.zig") },
    .{ .name = "appwindow/tmux_bridge.zig", .text = @embedFile("../appwindow/tmux_bridge.zig") },
};

const create_marker = "create(TabState)";
const literal_marker = ".* = .{";

/// Number of `create(TabState)` sites not followed by a whole-struct literal
/// before the next site (or the end of the source).
fn piecewiseSites(source: []const u8) usize {
    var missing: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, source, pos, create_marker)) |at| {
        const after = at + create_marker.len;
        const next = std.mem.indexOfPos(u8, source, after, create_marker) orelse source.len;
        if (std.mem.indexOf(u8, source[after..next], literal_marker) == null) missing += 1;
        pos = after;
    }
    return missing;
}

test "every heap-created TabState is initialized with a struct literal" {
    for (sources) |source| {
        const missing = piecewiseSites(source.text);
        if (missing != 0) {
            std.debug.print(
                "tab_state_init_guard: {s} has {d} `create(TabState)` site(s) without `t.* = .{{ ... }}`. " ++
                    "Field-by-field init skips declaration defaults and leaves forgotten fields undefined.\n",
                .{ source.name, missing },
            );
            return error.TabStatePiecewiseInit;
        }
    }
}

test "piecewiseSites flags field-by-field init and accepts a literal" {
    try std.testing.expectEqual(@as(usize, 0), piecewiseSites(
        \\const t = try gpa.create(TabState);
        \\t.* = .{ .tree = .empty };
    ));
    try std.testing.expectEqual(@as(usize, 1), piecewiseSites(
        \\const a = try gpa.create(TabState);
        \\a.kind = .terminal;
        \\const b = try gpa.create(TabState);
        \\b.* = .{ .tree = .empty };
    ));
}
