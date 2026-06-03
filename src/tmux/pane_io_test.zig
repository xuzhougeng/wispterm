//! Posix-only tests for the tmux pane I/O bridge (`pane.zig`).
//!
//! Uses real `Pty.openVirtual` socketpairs: the `pty` end stands in for a
//! pane's Surface (it reads rendered `%output` and writes keystrokes), while
//! the `controller_fd` is owned by the PaneMap under test. Kept out of
//! `pane.zig` so that module stays portable (std + session only); the
//! libc/socketpair dependency lives here, like `platform/pty_virtual_test.zig`.

const std = @import("std");
const pane = @import("pane.zig");
const session = @import("session.zig");
const pty = @import("../platform/pty.zig");

/// A PaneSink that ignores output — for keystroke-only tests.
fn nullSink() session.PaneSink {
    return .{
        .ctx = undefined,
        .writeFn = struct {
            fn f(_: *anyopaque, _: usize, _: []const u8) void {}
        }.f,
    };
}

test "PaneMap.sink delivers %output to the matching pane's controller fd" {
    const alloc = std.testing.allocator;
    var pair = try pty.Pty.openVirtual(.{ .ws_col = 80, .ws_row = 24 });
    defer pair.pty.deinit(); // the Surface end

    var map = pane.PaneMap.init(alloc);
    defer map.deinit(); // closes controller_fd
    try map.addPane(7, pair.controller_fd);

    map.sink().write(7, "hello");

    var buf: [16]u8 = undefined;
    const n = try pair.pty.readOutput(&buf);
    try std.testing.expectEqualStrings("hello", buf[0..n]);
}

test "PaneMap.sink drops output for an unknown pane" {
    const alloc = std.testing.allocator;
    var map = pane.PaneMap.init(alloc);
    defer map.deinit();
    // No panes registered: must be a safe no-op, not a crash.
    map.sink().write(3, "ignored");
}

test "Session %output flows through PaneMap.sink, unescaped, to the pane" {
    const alloc = std.testing.allocator;
    var pair = try pty.Pty.openVirtual(.{ .ws_col = 80, .ws_row = 24 });
    defer pair.pty.deinit();

    var map = pane.PaneMap.init(alloc);
    defer map.deinit();
    try map.addPane(2, pair.controller_fd);

    var s = session.Session.init(alloc, map.sink(), 80, 24);
    defer s.deinit();
    // \033 octal-escapes to ESC (0x1b); session unescapes before the sink.
    try s.feed("%output %2 ab\\033c\n");

    var buf: [16]u8 = undefined;
    const n = try pair.pty.readOutput(&buf);
    try std.testing.expectEqualSlices(u8, &.{ 'a', 'b', 0x1b, 'c' }, buf[0..n]);
}

test "PaneMap.removePane unregisters the pane and closes its fd" {
    const alloc = std.testing.allocator;
    var pair = try pty.Pty.openVirtual(.{ .ws_col = 80, .ws_row = 24 });
    defer pair.pty.deinit();

    var map = pane.PaneMap.init(alloc);
    defer map.deinit(); // pane already gone; must not double-close
    try map.addPane(5, pair.controller_fd);

    map.removePane(5);
    try std.testing.expect(map.find(5) == null);
    // Output to a removed pane is dropped (no crash).
    map.sink().write(5, "gone");
}

test "pumpKeystrokes forwards a pane's keystrokes as a hex send-keys" {
    const alloc = std.testing.allocator;
    var pair = try pty.Pty.openVirtual(.{ .ws_col = 80, .ws_row = 24 });
    defer pair.pty.deinit();

    var map = pane.PaneMap.init(alloc);
    defer map.deinit();
    try map.addPane(4, pair.controller_fd);

    var s = session.Session.init(alloc, nullSink(), 80, 24);
    defer s.deinit();

    // The Surface writes keystrokes into its pty; the bytes surface on the
    // controller_fd, which the pump turns into a hex send-keys for pane %4.
    try pair.pty.writeInput("ls\n"); // l=6c s=73 \n=0a
    try map.pumpKeystrokes(&s);
    try std.testing.expectEqualStrings("send-keys -t %4 -H 6c 73 0a\n", s.pendingCommands());
}

test "pumpKeystrokes routes each pane to its own pane id" {
    const alloc = std.testing.allocator;
    var a = try pty.Pty.openVirtual(.{ .ws_col = 80, .ws_row = 24 });
    defer a.pty.deinit();
    var b = try pty.Pty.openVirtual(.{ .ws_col = 80, .ws_row = 24 });
    defer b.pty.deinit();

    var map = pane.PaneMap.init(alloc);
    defer map.deinit();
    try map.addPane(1, a.controller_fd);
    try map.addPane(2, b.controller_fd);

    var s = session.Session.init(alloc, nullSink(), 80, 24);
    defer s.deinit();

    try a.pty.writeInput("x"); // x=78
    try b.pty.writeInput("y"); // y=79
    try map.pumpKeystrokes(&s);

    const cmds = s.pendingCommands();
    try std.testing.expect(std.mem.indexOf(u8, cmds, "send-keys -t %1 -H 78\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmds, "send-keys -t %2 -H 79\n") != null);
}

test "pumpKeystrokes is a no-op when no keystrokes are pending" {
    const alloc = std.testing.allocator;
    var pair = try pty.Pty.openVirtual(.{ .ws_col = 80, .ws_row = 24 });
    defer pair.pty.deinit();

    var map = pane.PaneMap.init(alloc);
    defer map.deinit();
    try map.addPane(9, pair.controller_fd);

    var s = session.Session.init(alloc, nullSink(), 80, 24);
    defer s.deinit();

    try map.pumpKeystrokes(&s); // nothing written → nothing queued
    try std.testing.expectEqual(@as(usize, 0), s.pendingCommands().len);
}
