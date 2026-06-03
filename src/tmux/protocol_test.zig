//! Wiring tests across the two pure tmux modules. Kept separate so neither
//! `control.zig` nor `layout.zig` imports the other.

const std = @import("std");
const control = @import("control.zig");
const layout = @import("layout.zig");

fn feed(p: *control.Parser, s: []const u8) !?control.Notification {
    var result: ?control.Notification = null;
    for (s) |b| {
        if (try p.put(b)) |n| result = n;
    }
    return result;
}

test "a %layout-change layout string parses into a pane tree" {
    var p = control.Parser.init(std.testing.allocator);
    defer p.deinit();

    const n = (try feed(&p, "%layout-change @1 bd1b,80x24,0,0{40x24,0,0,1,39x24,41,0,2} bd1b,80x24,0,0{40x24,0,0,1,39x24,41,0,2} *\n")).?;
    try std.testing.expectEqual(@as(usize, 1), n.layout_change.window_id);

    var tree = try layout.parse(std.testing.allocator, n.layout_change.layout);
    defer tree.deinit();

    const split = tree.root.split;
    try std.testing.expectEqual(layout.Dir.horizontal, split.dir);
    try std.testing.expectEqual(@as(usize, 2), split.children.len);
    try std.testing.expectEqual(@as(usize, 1), split.children[0].leaf.pane_id);
    try std.testing.expectEqual(@as(usize, 2), split.children[1].leaf.pane_id);
}
