//! POSIX foreground-process query: `tcgetpgrp` on the PTY master names the
//! foreground process group; its leader is the program the user is talking
//! to. Linux reads `/proc/<pid>/comm`; macOS asks libproc (`proc_name`).

const std = @import("std");
const builtin = @import("builtin");
const Pty = @import("pty.zig").Pty;
const Command = @import("pty_command.zig").Command;
const facade = @import("foreground_process.zig");

extern "c" fn tcgetpgrp(fd: c_int) std.c.pid_t;
extern "c" fn proc_name(pid: c_int, buffer: [*]u8, buffersize: u32) c_int;

pub fn query(pty: *const Pty, command: *const Command, buf: []u8, _: facade.Recognizer) ?facade.Info {
    if (pty.is_virtual) return null;
    const pgid = tcgetpgrp(pty.master);
    if (pgid <= 0) return null;
    if (command.pid > 0 and pgid == command.pid) return .{ .name = "", .is_shell = true };
    const name = processName(@intCast(pgid), buf) orelse "";
    return .{ .name = name, .is_shell = false };
}

fn processName(pid: i32, buf: []u8) ?[]const u8 {
    if (builtin.os.tag == .macos) {
        if (buf.len == 0) return null;
        const n = proc_name(pid, buf.ptr, @intCast(@min(buf.len, std.math.maxInt(u32))));
        if (n <= 0) return null;
        return std.mem.trim(u8, buf[0..@intCast(n)], " \r\n\t\x00");
    }
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/comm", .{pid}) catch return null;
    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();
    const n = file.readAll(buf) catch return null;
    return std.mem.trim(u8, buf[0..n], " \r\n\t\x00");
}
