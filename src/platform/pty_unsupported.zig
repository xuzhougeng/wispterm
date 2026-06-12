const pty_command = @import("pty_command.zig");

pub const ReadError = error{ UnsupportedPty, ReadInterrupted, BrokenPipe, ReadFailed };
pub const WriteError = error{ UnsupportedPty, BrokenPipe, WriteFailed };

pub const winsize = struct {
    ws_col: u16,
    ws_row: u16,
    ws_xpixel: u16 = 0,
    ws_ypixel: u16 = 0,
};

pub const Pty = struct {
    size: winsize,

    pub fn open(size: winsize) !Pty {
        _ = size;
        return error.UnsupportedPty;
    }

    pub fn deinit(self: *Pty) void {
        _ = self;
    }

    pub fn getSize(self: *const Pty) winsize {
        return self.size;
    }

    pub fn setSize(self: *Pty, s: winsize) !void {
        _ = self;
        _ = s;
        return error.UnsupportedPty;
    }

    pub fn startCommand(self: *Pty, command: *pty_command.Command, command_line: pty_command.CommandLine, cwd: pty_command.Cwd) !void {
        _ = self;
        _ = command;
        _ = command_line;
        _ = cwd;
        return error.UnsupportedPty;
    }

    pub fn readOutput(self: *Pty, buffer: []u8) ReadError!usize {
        _ = self;
        _ = buffer;
        return error.UnsupportedPty;
    }

    pub fn writeInput(self: *Pty, data: []const u8) WriteError!void {
        _ = self;
        _ = data;
        return error.UnsupportedPty;
    }

    pub fn outputAvailable(self: *Pty) ?usize {
        _ = self;
        return null;
    }

    pub fn cancelOutputRead(self: *Pty) void {
        _ = self;
    }
};

pub fn setConsoleHostPreference(pref: @import("console_host_policy.zig").Preference) void {
    _ = pref;
}
