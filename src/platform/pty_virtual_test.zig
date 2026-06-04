//! Tests for the virtual PTY pair used by tmux panes. Kept out of concrete
//! backend files so registering it does not pull in unrelated backend tests.

const std = @import("std");
const pty = @import("pty.zig");

test "virtual pty round-trips bytes in both directions" {
    var pair = try pty.Pty.openVirtual(.{ .ws_col = 80, .ws_row = 24 });
    defer pair.pty.deinit();
    defer pair.controller.deinit();

    // controller -> surface: controller output is read via readOutput.
    pair.controller.writeOutput("hi");
    var buf: [16]u8 = undefined;
    const n = try pair.pty.readOutput(&buf);
    try std.testing.expectEqualStrings("hi", buf[0..n]);

    // surface -> controller: writeInput is read from the controller side.
    try pair.pty.writeInput("yo");
    var buf2: [16]u8 = undefined;
    const m = pair.controller.readInput(&buf2) orelse return error.ExpectedControllerInput;
    try std.testing.expectEqualStrings("yo", buf2[0..m]);
}

test "virtual pty setSize is a no-op that still records the size" {
    var pair = try pty.Pty.openVirtual(.{ .ws_col = 80, .ws_row = 24 });
    defer pair.pty.deinit();
    defer pair.controller.deinit();

    try pair.pty.setSize(.{ .ws_col = 100, .ws_row = 30 });
    try std.testing.expectEqual(@as(u16, 100), pair.pty.getSize().ws_col);
    try std.testing.expectEqual(@as(u16, 30), pair.pty.getSize().ws_row);
}

test "virtual pty outputAvailable reflects pending bytes" {
    var pair = try pty.Pty.openVirtual(.{ .ws_col = 80, .ws_row = 24 });
    defer pair.pty.deinit();
    defer pair.controller.deinit();

    pair.controller.writeOutput("abc");
    const avail = pair.pty.outputAvailable() orelse 0;
    try std.testing.expect(avail >= 3);
}
