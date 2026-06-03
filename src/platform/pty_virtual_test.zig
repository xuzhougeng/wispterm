//! Posix-only tests for the virtual (socketpair-backed) Pty. Kept out of
//! `pty_posix.zig` so registering it does not pull in that file's other,
//! currently-unregistered tests. Runs in the full suite (libc-linked).

const std = @import("std");
const pty = @import("pty.zig");

test "virtual pty round-trips bytes in both directions" {
    var pair = try pty.Pty.openVirtual(.{ .ws_col = 80, .ws_row = 24 });
    defer pair.pty.deinit();
    defer std.posix.close(pair.controller_fd);

    // controller -> surface: data written to controller_fd is read via readOutput.
    _ = try std.posix.write(pair.controller_fd, "hi");
    var buf: [16]u8 = undefined;
    const n = try pair.pty.readOutput(&buf);
    try std.testing.expectEqualStrings("hi", buf[0..n]);

    // surface -> controller: writeInput is read from controller_fd.
    try pair.pty.writeInput("yo");
    var buf2: [16]u8 = undefined;
    const m = try std.posix.read(pair.controller_fd, &buf2);
    try std.testing.expectEqualStrings("yo", buf2[0..m]);
}

test "virtual pty setSize is a no-op that still records the size" {
    var pair = try pty.Pty.openVirtual(.{ .ws_col = 80, .ws_row = 24 });
    defer pair.pty.deinit();
    defer std.posix.close(pair.controller_fd);

    try pair.pty.setSize(.{ .ws_col = 100, .ws_row = 30 });
    try std.testing.expectEqual(@as(u16, 100), pair.pty.getSize().ws_col);
    try std.testing.expectEqual(@as(u16, 30), pair.pty.getSize().ws_row);
}

test "virtual pty outputAvailable reflects pending bytes" {
    var pair = try pty.Pty.openVirtual(.{ .ws_col = 80, .ws_row = 24 });
    defer pair.pty.deinit();
    defer std.posix.close(pair.controller_fd);

    _ = try std.posix.write(pair.controller_fd, "abc");
    const avail = pair.pty.outputAvailable() orelse 0;
    try std.testing.expect(avail >= 3);
}
