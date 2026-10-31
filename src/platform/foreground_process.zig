//! Platform facade: which program is in the foreground of a terminal's PTY.
//! Used by terminal-agent screen detection to know *which* agent's rules to
//! apply (and to notice when the agent has exited back to the shell).
//!
//! POSIX asks the PTY for its foreground process group (`tcgetpgrp`) and
//! names that process. Windows has no foreground notion for a ConPTY, so it
//! walks the shell's descendants and reports the first one the caller
//! recognizes (else the deepest one). Other targets report nothing.
//!
//! The platform layer never classifies: `recognizes` is the caller's name
//! table, so the agent vocabulary stays in `terminal_agents/`.

const std = @import("std");
const builtin = @import("builtin");
const Pty = @import("pty.zig").Pty;
const Command = @import("pty_command.zig").Command;

pub const Backend = enum { posix, windows, unsupported };

pub fn backendForOs(os_tag: std.Target.Os.Tag) Backend {
    return switch (os_tag) {
        .windows => .windows,
        .linux, .macos => .posix,
        else => .unsupported,
    };
}

const impl = switch (backendForOs(builtin.os.tag)) {
    .posix => @import("foreground_process_posix.zig"),
    .windows => @import("foreground_process_windows.zig"),
    .unsupported => @import("foreground_process_unsupported.zig"),
};

pub const Info = struct {
    /// Process name (basename or image name), empty when it could not be read.
    name: []const u8,
    /// True when the shell itself is in the foreground (no child running).
    is_shell: bool,
};

/// Name predicate supplied by the caller (see `terminal_agents/detector.zig`).
pub const Recognizer = *const fn (name: []const u8) bool;

/// Best-effort foreground process of `pty`. Null when the platform cannot
/// tell (virtual PTYs, unsupported targets, query failures). `buf` backs the
/// returned name.
pub fn query(pty: *const Pty, command: *const Command, buf: []u8, recognizes: Recognizer) ?Info {
    return impl.query(pty, command, buf, recognizes);
}

test "facade maps every OS to a backend" {
    try std.testing.expectEqual(Backend.windows, backendForOs(.windows));
    try std.testing.expectEqual(Backend.posix, backendForOs(.macos));
    try std.testing.expectEqual(Backend.posix, backendForOs(.linux));
    try std.testing.expectEqual(Backend.unsupported, backendForOs(.freebsd));
}
