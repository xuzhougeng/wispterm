//! POSIX PTY backend (Linux + macOS).
//!
//! The ioctl request numbers are OS-dispatched: Linux uses `std.os.linux.T`,
//! macOS uses the BSD IOC-encoded constants below (verified values, but the
//! macOS path is compile-checked, not run, on the Linux dev box). The BSDs use
//! the same IOC scheme as macOS but their exact codes are unverified, so
//! `pty.zig`'s `backendForOs` still routes them to `.unsupported`.
//!
//! Mirrors the `Pty` API of `pty_windows.zig`. Uses libc (link with `-lc`):
//! `posix_openpt`/`grantpt`/`unlockpt`/`ptsname_r` to allocate a master fd plus
//! a slave device path, `fork`/`setsid`/`TIOCSCTTY`/`dup2`/`execvp` to launch
//! the child on the slave side, and a self-pipe so `cancelOutputRead` can break
//! the blocking `poll`-based `readOutput`.
const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const pty_command = @import("pty_command.zig");

const fd_t = c.fd_t;

/// ioctl request numbers, OS-dispatched. Linux: `std.os.linux.T` (per-arch).
/// macOS: BSD `_IOW('t',103,struct winsize)` etc. — fixed values. Untyped so
/// they coerce to whatever `c.ioctl`'s request param is on each target (the
/// macOS values exceed i32, and macOS `ioctl` takes `c_ulong`).
const T = switch (builtin.os.tag) {
    .macos => struct {
        pub const IOCSWINSZ = 0x80087467; // _IOW('t', 103, struct winsize)
        pub const IOCSCTTY = 0x20007461; // _IO('t', 97)
        pub const FIONREAD = 0x4004667f; // _IOR('f', 127, int)
    },
    else => std.os.linux.T,
};

// C `ioctl` takes `unsigned long` for the request on both Linux and macOS;
// std.c.ioctl types it as c_int, which can't hold the macOS IOC codes (> i32).
extern "c" fn ioctl(fd: fd_t, request: c_ulong, ...) c_int;
extern "c" fn posix_openpt(oflag: c_int) c_int;
extern "c" fn grantpt(fd: c_int) c_int;
extern "c" fn unlockpt(fd: c_int) c_int;
extern "c" fn ptsname_r(fd: c_int, buf: [*]u8, buflen: usize) c_int;
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;
/// Raw `_exit(2)` — used in the forked child so we never run libc `atexit`
/// handlers or flush stdio buffers inherited from the parent.
extern "c" fn _exit(code: c_int) noreturn;

const SLAVE_PATH_MAX = 128;
const MAX_ARGV = 64;
const ARG_BUF = 1024;

fn errno() c.E {
    return @enumFromInt(c._errno().*);
}

pub const ReadError = error{ ReadInterrupted, BrokenPipe, ReadFailed };
pub const WriteError = error{ BrokenPipe, WriteFailed };

pub const winsize = struct {
    ws_col: u16,
    ws_row: u16,
    ws_xpixel: u16 = 0,
    ws_ypixel: u16 = 0,
};

/// OS `struct winsize` layout: row, col, xpixel, ypixel.
const OsWinsize = extern struct {
    ws_row: u16,
    ws_col: u16,
    ws_xpixel: u16,
    ws_ypixel: u16,
};

fn osWinsize(s: winsize) OsWinsize {
    return .{
        .ws_row = s.ws_row,
        .ws_col = s.ws_col,
        .ws_xpixel = s.ws_xpixel,
        .ws_ypixel = s.ws_ypixel,
    };
}

pub const Pty = struct {
    master: fd_t,
    slave_path: [SLAVE_PATH_MAX]u8,
    size: winsize,
    cancel_pipe: [2]fd_t,

    pub fn open(size: winsize) !Pty {
        var self: Pty = undefined;
        self.size = size;

        const open_flags = std.posix.O{ .ACCMODE = .RDWR, .NOCTTY = true };
        const o_int: c_int = @bitCast(open_flags);
        const master = posix_openpt(o_int);
        if (master < 0) return error.OpenPtFailed;
        errdefer _ = c.close(master);

        if (grantpt(master) != 0) return error.GrantPtFailed;
        if (unlockpt(master) != 0) return error.UnlockPtFailed;

        self.slave_path = std.mem.zeroes([SLAVE_PATH_MAX]u8);
        if (ptsname_r(master, &self.slave_path, SLAVE_PATH_MAX) != 0) {
            return error.PtsnameFailed;
        }

        self.master = master;

        // Self-pipe used to interrupt the blocking poll in readOutput.
        self.cancel_pipe = try std.posix.pipe();
        errdefer {
            std.posix.close(self.cancel_pipe[0]);
            std.posix.close(self.cancel_pipe[1]);
        }

        return self;
    }

    pub fn deinit(self: *Pty) void {
        if (self.master >= 0) {
            _ = c.close(self.master);
            self.master = -1;
        }
        if (self.cancel_pipe[0] >= 0) {
            std.posix.close(self.cancel_pipe[0]);
            self.cancel_pipe[0] = -1;
        }
        if (self.cancel_pipe[1] >= 0) {
            std.posix.close(self.cancel_pipe[1]);
            self.cancel_pipe[1] = -1;
        }
    }

    pub fn getSize(self: *const Pty) winsize {
        return self.size;
    }

    pub fn setSize(self: *Pty, s: winsize) !void {
        try setWindowSize(self.master, self.slavePathSlice(), s);
        self.size = s;
    }

    pub fn startCommand(self: *Pty, command: *pty_command.Command, command_line: pty_command.CommandLine, cwd: pty_command.Cwd) !void {
        const pid = std.posix.fork() catch return error.ForkFailed;
        if (pid == 0) {
            // Child: set up the slave as the controlling tty, then exec.
            childExec(self.master, self.slave_path[0..], self.cancel_pipe, self.size, command_line, cwd);
            // childExec never returns; if it somehow does, bail out.
            _exit(127);
        }
        // Parent: keep the master open; record the child pid.
        command.pid = pid;
    }

    pub fn readOutput(self: *Pty, buffer: []u8) ReadError!usize {
        if (buffer.len == 0) return 0;

        while (true) {
            var fds = [2]std.posix.pollfd{
                .{ .fd = self.master, .events = std.posix.POLL.IN, .revents = 0 },
                .{ .fd = self.cancel_pipe[0], .events = std.posix.POLL.IN, .revents = 0 },
            };

            const ready = c.poll(&fds, fds.len, -1);
            if (ready < 0) {
                if (errno() == c.E.INTR) return error.ReadInterrupted;
                return error.ReadFailed;
            }

            // Cancellation requested: drain the self-pipe and report interruption.
            if (fds[1].revents & (std.posix.POLL.IN | std.posix.POLL.HUP) != 0) {
                var drain: [64]u8 = undefined;
                _ = c.read(self.cancel_pipe[0], &drain, drain.len);
                return error.ReadInterrupted;
            }

            if (fds[0].revents & (std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR) != 0) {
                const n = c.read(self.master, buffer.ptr, buffer.len);
                if (n < 0) {
                    return switch (errno()) {
                        c.E.INTR => error.ReadInterrupted,
                        // Linux signals slave-side close via EIO on the master.
                        c.E.IO => error.BrokenPipe,
                        else => error.ReadFailed,
                    };
                }
                return @intCast(n);
            }

            // No data and not cancelled (e.g. spurious wakeup); loop again.
        }
    }

    pub fn writeInput(self: *Pty, data: []const u8) WriteError!void {
        var offset: usize = 0;
        while (offset < data.len) {
            const n = c.write(self.master, data[offset..].ptr, data.len - offset);
            if (n < 0) {
                return switch (errno()) {
                    c.E.INTR => continue,
                    c.E.PIPE, c.E.IO => error.BrokenPipe,
                    else => error.WriteFailed,
                };
            }
            if (n == 0) return error.BrokenPipe;
            offset += @intCast(n);
        }
    }

    pub fn outputAvailable(self: *Pty) ?usize {
        var n: c_int = 0;
        if (ioctl(self.master, T.FIONREAD, &n) != 0) {
            return readableFallback(self.master);
        }
        if (n < 0) return null;
        if (n == 0 and builtin.os.tag == .macos) {
            return readableFallback(self.master) orelse 0;
        }
        return @intCast(n);
    }

    pub fn cancelOutputRead(self: *Pty) void {
        const byte = [1]u8{0};
        _ = c.write(self.cancel_pipe[1], &byte, 1);
    }

    fn slavePathSlice(self: *const Pty) []const u8 {
        return std.mem.sliceTo(self.slave_path[0..], 0);
    }
};

fn setWindowSize(master: fd_t, slave_path: []const u8, size: winsize) !void {
    var os_ws = osWinsize(size);
    if (builtin.os.tag == .macos) {
        var path_buf: [SLAVE_PATH_MAX]u8 = undefined;
        if (slave_path.len >= path_buf.len) return error.SetSizeFailed;
        @memcpy(path_buf[0..slave_path.len], slave_path);
        path_buf[slave_path.len] = 0;

        const open_flags = std.posix.O{ .ACCMODE = .RDWR, .NOCTTY = true };
        const slave = c.open(@ptrCast(&path_buf), open_flags, @as(c.mode_t, 0));
        if (slave < 0) return error.SetSizeFailed;
        defer _ = c.close(slave);
        if (ioctl(slave, T.IOCSWINSZ, &os_ws) != 0) return error.SetSizeFailed;
        return;
    }

    if (ioctl(master, T.IOCSWINSZ, &os_ws) != 0) return error.SetSizeFailed;
}

fn readableFallback(fd: fd_t) ?usize {
    var fds = [1]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
    const ready = c.poll(&fds, 1, 0);
    if (ready < 0) return null;
    if (ready == 0) return 0;
    if (fds[0].revents & std.posix.POLL.IN != 0) return 1;
    return 0;
}

/// Runs entirely in the forked child. Sets up the controlling terminal on the
/// slave device, wires stdio to it, optionally changes directory, then execs
/// the parsed command line. Never returns on success; on any failure it exits
/// with code 127.
fn childExec(
    master: fd_t,
    slave_path: []const u8,
    cancel_pipe: [2]fd_t,
    size: winsize,
    command_line: pty_command.CommandLine,
    cwd: pty_command.Cwd,
) void {
    // New session so we can claim a controlling terminal.
    _ = c.setsid();

    // Build a NUL-terminated copy of the slave path on the stack.
    var path_buf: [SLAVE_PATH_MAX]u8 = undefined;
    var path_len: usize = 0;
    while (path_len < slave_path.len and slave_path[path_len] != 0) : (path_len += 1) {
        path_buf[path_len] = slave_path[path_len];
    }
    if (path_len >= path_buf.len) _exit(127);
    path_buf[path_len] = 0;

    const open_flags = std.posix.O{ .ACCMODE = .RDWR };
    const slave = c.open(@ptrCast(&path_buf), open_flags, @as(c.mode_t, 0));
    if (slave < 0) _exit(127);

    var os_ws = osWinsize(size);
    _ = ioctl(slave, T.IOCSWINSZ, &os_ws);

    // Claim the slave as the controlling terminal for this session.
    _ = ioctl(slave, T.IOCSCTTY, @as(c_int, 0));

    _ = c.dup2(slave, 0);
    _ = c.dup2(slave, 1);
    _ = c.dup2(slave, 2);

    if (slave > 2) _ = c.close(slave);
    _ = c.close(master);
    _ = c.close(cancel_pipe[0]);
    _ = c.close(cancel_pipe[1]);

    if (cwd) |dir| {
        _ = c.chdir(dir);
    }

    // GUI-launched apps on macOS inherit a minimal environment from launchd, so
    // TERM is usually unset. Without it, shells fall back to "dumb" or other
    // limited profiles — Starship rendered a stub prompt, zsh-autosuggestions
    // miscalculated redraw widths, and line-edit redraws left stale glyphs on
    // screen. xterm-256color is the most broadly supported terminfo entry and
    // matches the SGR / cursor-control set our ghostty-vt parser implements.
    _ = setenv("TERM", "xterm-256color", 1);
    _ = setenv("COLORTERM", "truecolor", 1);
    _ = setenv("TERM_PROGRAM", "phantty", 1);
    // Some shells refuse to load completions when TERMINFO points at a value
    // that doesn't exist for our TERM choice. Clearing it lets ncurses fall
    // back to the system database.
    _ = unsetenv("TERMINFO");

    // Parse command line into argv (split on ASCII whitespace).
    var arg_storage: [ARG_BUF]u8 = undefined;
    var argv: [MAX_ARGV + 1]?[*:0]const u8 = undefined;
    const argc = parseArgv(command_line, &arg_storage, &argv);
    if (argc == 0) _exit(127);
    argv[argc] = null;

    _ = execvp(argv[0].?, @ptrCast(&argv));
    // execvp only returns on failure.
    _exit(127);
}

/// Splits `command_line` on ASCII whitespace into NUL-terminated argv entries
/// written into `storage`. Returns the argument count (0 if empty / overflow).
fn parseArgv(
    command_line: []const u8,
    storage: *[ARG_BUF]u8,
    argv: *[MAX_ARGV + 1]?[*:0]const u8,
) usize {
    var argc: usize = 0;
    var write_pos: usize = 0;
    var i: usize = 0;
    const n = command_line.len;
    while (i < n) {
        // Skip leading whitespace.
        while (i < n and std.ascii.isWhitespace(command_line[i])) : (i += 1) {}
        if (i >= n) break;
        if (argc >= MAX_ARGV) return 0;

        const arg_start = write_pos;
        while (i < n and !std.ascii.isWhitespace(command_line[i])) : (i += 1) {
            if (write_pos + 1 >= storage.len) return 0;
            storage[write_pos] = command_line[i];
            write_pos += 1;
        }
        if (write_pos + 1 > storage.len) return 0;
        storage[write_pos] = 0;
        write_pos += 1;

        argv[argc] = @ptrCast(&storage[arg_start]);
        argc += 1;
    }
    return argc;
}

const backend_facade = @import("pty.zig");

test "posix backend selected for linux + macos; bsd/wasi unsupported" {
    try std.testing.expectEqual(backend_facade.Backend.posix, backend_facade.backendForOs(.linux));
    try std.testing.expectEqual(backend_facade.Backend.posix, backend_facade.backendForOs(.macos));
    try std.testing.expectEqual(backend_facade.Backend.windows, backend_facade.backendForOs(.windows));
    // BSD IOC codes are unverified; wasi has no pty.
    try std.testing.expectEqual(backend_facade.Backend.unsupported, backend_facade.backendForOs(.freebsd));
    try std.testing.expectEqual(backend_facade.Backend.unsupported, backend_facade.backendForOs(.wasi));
}

test "open then resize is reflected by getSize" {
    var pty = try Pty.open(.{ .ws_col = 80, .ws_row = 24 });
    defer pty.deinit();

    try std.testing.expectEqual(@as(u16, 80), pty.getSize().ws_col);
    try std.testing.expectEqual(@as(u16, 24), pty.getSize().ws_row);

    try pty.setSize(.{ .ws_col = 120, .ws_row = 40 });
    try std.testing.expectEqual(@as(u16, 120), pty.getSize().ws_col);
    try std.testing.expectEqual(@as(u16, 40), pty.getSize().ws_row);
}

test "spawn child writes output that readOutput receives" {
    var pty = try Pty.open(.{ .ws_col = 80, .ws_row = 24 });
    defer pty.deinit();

    var command: pty_command.Command = .{};
    defer command.deinit();

    try pty.startCommand(&command, "/bin/echo phantty-marker", null);

    var buf: [4096]u8 = undefined;
    var collected: std.ArrayListUnmanaged(u8) = .empty;
    defer collected.deinit(std.testing.allocator);

    // Bounded loop: read until we see the marker or the child exits / iterations run out.
    var iterations: usize = 0;
    var saw_marker = false;
    while (iterations < 200) : (iterations += 1) {
        const n = pty.readOutput(&buf) catch |err| switch (err) {
            error.BrokenPipe => break,
            error.ReadInterrupted => continue,
            else => return err,
        };
        if (n == 0) break;
        try collected.appendSlice(std.testing.allocator, buf[0..n]);
        if (std.mem.indexOf(u8, collected.items, "phantty-marker") != null) {
            saw_marker = true;
            break;
        }
    }

    try std.testing.expect(saw_marker);
}

test "child exit surfaces BrokenPipe/EOF and wait reports exit code" {
    var pty = try Pty.open(.{ .ws_col = 80, .ws_row = 24 });
    defer pty.deinit();

    var command: pty_command.Command = .{};
    defer command.deinit();

    // Spawn an interactive shell, then drive it via writeInput (matching the
    // real IO model). The command line is whitespace-split into argv, so we
    // avoid embedded-quote arguments and feed the script over stdin instead.
    try pty.startCommand(&command, "/bin/sh", null);
    try pty.writeInput("printf hi\nexit 7\n");

    var buf: [4096]u8 = undefined;
    var saw_hi = false;
    var got_eof = false;
    var iterations: usize = 0;
    while (iterations < 500) : (iterations += 1) {
        const n = pty.readOutput(&buf) catch |err| switch (err) {
            error.BrokenPipe => {
                got_eof = true;
                break;
            },
            error.ReadInterrupted => continue,
            else => return err,
        };
        if (n == 0) {
            got_eof = true;
            break;
        }
        if (std.mem.indexOf(u8, buf[0..n], "hi") != null) saw_hi = true;
    }

    try std.testing.expect(saw_hi);
    try std.testing.expect(got_eof);

    // Blocking wait must reap the child and report the exit status.
    const exit = (try command.wait(true)) orelse return error.ExpectedExit;
    switch (exit) {
        .exited => |code| try std.testing.expectEqual(@as(u32, 7), code),
        .unknown => return error.UnexpectedUnknownExit,
    }
}

test "outputAvailable returns a byte count after child writes" {
    var pty = try Pty.open(.{ .ws_col = 80, .ws_row = 24 });
    defer pty.deinit();

    var command: pty_command.Command = .{};
    defer command.deinit();

    try pty.startCommand(&command, "/bin/echo phantty-avail", null);

    // Wait (bounded) until the kernel reports bytes available on the master.
    var iterations: usize = 0;
    var available: usize = 0;
    while (iterations < 500) : (iterations += 1) {
        if (pty.outputAvailable()) |n| {
            if (n > 0) {
                available = n;
                break;
            }
        }
        std.Thread.sleep(2 * std.time.ns_per_ms);
    }

    try std.testing.expect(available > 0);

    // Drain so the child can exit cleanly and deinit doesn't leave a zombie.
    var buf: [4096]u8 = undefined;
    _ = pty.readOutput(&buf) catch {};
}

test "cancelOutputRead interrupts a blocking readOutput" {
    var pty = try Pty.open(.{ .ws_col = 80, .ws_row = 24 });
    defer pty.deinit();

    // No child spawned: readOutput would block on poll forever without a cancel.
    const Ctx = struct {
        pty: *Pty,
        fn run(p: *Pty) void {
            std.Thread.sleep(20 * std.time.ns_per_ms);
            p.cancelOutputRead();
        }
    };
    var thread = try std.Thread.spawn(.{}, Ctx.run, .{&pty});
    defer thread.join();

    var buf: [16]u8 = undefined;
    const result = pty.readOutput(&buf);
    try std.testing.expectError(error.ReadInterrupted, result);
}
