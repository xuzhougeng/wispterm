const std = @import("std");
const builtin = @import("builtin");

pub const Backend = enum {
    windows,
    posix,
    unsupported,
};

pub fn backendForOs(os_tag: std.Target.Os.Tag) Backend {
    return switch (os_tag) {
        .windows => .windows,
        // Linux (verified) + macOS (OS-dispatched ioctl constants in
        // pty_posix.zig, compile-checked here, runnable on a Mac). The BSDs use
        // the same IOC scheme as macOS but their exact request codes are
        // unverified, so they stay unsupported until added on real hardware.
        .linux, .macos => .posix,
        else => .unsupported,
    };
}

const impl = switch (backendForOs(builtin.os.tag)) {
    .windows => @import("pty_windows.zig"),
    .posix => @import("pty_posix.zig"),
    .unsupported => @import("pty_unsupported.zig"),
};

pub const ReadError = impl.ReadError;
pub const WriteError = impl.WriteError;
pub const winsize = impl.winsize;
pub const Pty = impl.Pty;

test "platform pty exposes size and lifecycle API" {
    try std.testing.expect(@hasDecl(@This(), "winsize"));
    try std.testing.expect(@hasDecl(@This(), "Pty"));

    const PtyType = @This().Pty;
    const open_info = @typeInfo(@TypeOf(PtyType.open)).@"fn";
    try std.testing.expectEqual(@as(usize, 1), open_info.params.len);
    try std.testing.expect(open_info.params[0].type.? == @This().winsize);

    const get_size_info = @typeInfo(@TypeOf(PtyType.getSize)).@"fn";
    try std.testing.expectEqual(@as(usize, 1), get_size_info.params.len);
    try std.testing.expect(get_size_info.params[0].type.? == *const PtyType);

    const set_size_info = @typeInfo(@TypeOf(PtyType.setSize)).@"fn";
    try std.testing.expectEqual(@as(usize, 2), set_size_info.params.len);
    try std.testing.expect(set_size_info.params[0].type.? == *PtyType);
    try std.testing.expect(set_size_info.params[1].type.? == @This().winsize);

    const start_command_info = @typeInfo(@TypeOf(PtyType.startCommand)).@"fn";
    try std.testing.expectEqual(@as(usize, 4), start_command_info.params.len);
    try std.testing.expect(start_command_info.params[0].type.? == *PtyType);
}

test "platform pty owns pipe IO operations" {
    const PtyType = @This().Pty;

    const read_info = @typeInfo(@TypeOf(PtyType.readOutput)).@"fn";
    try std.testing.expectEqual(@as(usize, 2), read_info.params.len);
    try std.testing.expect(read_info.params[0].type.? == *PtyType);
    try std.testing.expect(read_info.params[1].type.? == []u8);

    const write_info = @typeInfo(@TypeOf(PtyType.writeInput)).@"fn";
    try std.testing.expectEqual(@as(usize, 2), write_info.params.len);
    try std.testing.expect(write_info.params[0].type.? == *PtyType);
    try std.testing.expect(write_info.params[1].type.? == []const u8);

    const peek_info = @typeInfo(@TypeOf(PtyType.outputAvailable)).@"fn";
    try std.testing.expectEqual(@as(usize, 1), peek_info.params.len);
    try std.testing.expect(peek_info.params[0].type.? == *PtyType);

    const cancel_info = @typeInfo(@TypeOf(PtyType.cancelOutputRead)).@"fn";
    try std.testing.expectEqual(@as(usize, 1), cancel_info.params.len);
    try std.testing.expect(cancel_info.params[0].type.? == *PtyType);
}

test "platform pty selects backend by target OS" {
    try std.testing.expectEqual(Backend.windows, backendForOs(.windows));
    try std.testing.expectEqual(Backend.posix, backendForOs(.linux));
    try std.testing.expectEqual(Backend.posix, backendForOs(.macos));
    // BSD IOC codes unverified; wasi has no pty.
    try std.testing.expectEqual(Backend.unsupported, backendForOs(.freebsd));
    try std.testing.expectEqual(Backend.unsupported, backendForOs(.wasi));
}
