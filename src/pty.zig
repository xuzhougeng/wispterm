//! App-facing PTY API.
//!
//! Platform-specific PTY creation and resizing lives in `platform/pty.zig`.

const platform_pty = @import("platform/pty.zig");

pub const winsize = platform_pty.winsize;
pub const Pty = platform_pty.Pty;

test "pty module re-exports platform PTY API" {
    const std = @import("std");
    try std.testing.expect(Pty == platform_pty.Pty);
    try std.testing.expect(winsize == platform_pty.winsize);
}

pub const ConsoleHostPreference = platform_pty.ConsoleHostPreference;
pub const setConsoleHostPreference = platform_pty.setConsoleHostPreference;
