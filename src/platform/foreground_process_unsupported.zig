//! Foreground-process query stub for targets without a PTY foreground notion.

const Pty = @import("pty.zig").Pty;
const Command = @import("pty_command.zig").Command;
const facade = @import("foreground_process.zig");

pub fn query(_: *const Pty, _: *const Command, _: []u8, _: facade.Recognizer) ?facade.Info {
    return null;
}
