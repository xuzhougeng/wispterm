//! tmux control-mode connection driver for Windows. Owns a hidden raw-pipe
//! `ssh.exe ... tmux -CC` transport, plus a `TmuxBridge` whose panes are backed
//! by virtual PTY pipe pairs.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Config = @import("../config.zig");
const platform_process = @import("../platform/process.zig");
const pty_command = @import("../platform/pty_command.zig");
const layout = @import("../tmux/layout.zig");
const bridge_mod = @import("tmux_bridge.zig");
const tab = @import("tab.zig");
const TmuxBridge = bridge_mod.TmuxBridge;
const windows = std.os.windows;

const HANDLE = windows.HANDLE;
const INVALID_HANDLE_VALUE = windows.INVALID_HANDLE_VALUE;
const DWORD = windows.DWORD;
const BOOL = windows.BOOL;

const startf_use_std_handles: DWORD = 0x00000100;
const create_no_window: DWORD = 0x08000000;
const create_unicode_environment: DWORD = 0x00000400;
const handle_flag_inherit: DWORD = 0x00000001;
const wait_object_0: DWORD = 0x00000000;
const wait_timeout: DWORD = 0x00000102;
const job_object_extended_limit_information: DWORD = 9;
const job_object_limit_kill_on_job_close: DWORD = 0x00002000;
const control_mode_handshake = "\x1bP1000p";
const handshake_tail_max = control_mode_handshake.len - 1;

const SECURITY_ATTRIBUTES = extern struct {
    nLength: DWORD,
    lpSecurityDescriptor: ?*anyopaque,
    bInheritHandle: BOOL,
};

const JOBOBJECT_BASIC_LIMIT_INFORMATION = extern struct {
    PerProcessUserTimeLimit: i64,
    PerJobUserTimeLimit: i64,
    LimitFlags: DWORD,
    MinimumWorkingSetSize: usize,
    MaximumWorkingSetSize: usize,
    ActiveProcessLimit: DWORD,
    Affinity: usize,
    PriorityClass: DWORD,
    SchedulingClass: DWORD,
};

const IO_COUNTERS = extern struct {
    ReadOperationCount: u64,
    WriteOperationCount: u64,
    OtherOperationCount: u64,
    ReadTransferCount: u64,
    WriteTransferCount: u64,
    OtherTransferCount: u64,
};

const JOBOBJECT_EXTENDED_LIMIT_INFORMATION = extern struct {
    BasicLimitInformation: JOBOBJECT_BASIC_LIMIT_INFORMATION,
    IoInfo: IO_COUNTERS,
    ProcessMemoryLimit: usize,
    JobMemoryLimit: usize,
    PeakProcessMemoryUsed: usize,
    PeakJobMemoryUsed: usize,
};

extern "kernel32" fn CreatePipe(
    hReadPipe: *HANDLE,
    hWritePipe: *HANDLE,
    lpPipeAttributes: ?*const SECURITY_ATTRIBUTES,
    nSize: DWORD,
) callconv(.winapi) BOOL;

extern "kernel32" fn SetHandleInformation(hObject: HANDLE, dwMask: DWORD, dwFlags: DWORD) callconv(.winapi) BOOL;

extern "kernel32" fn CreateProcessW(
    lpApplicationName: ?[*:0]const u16,
    lpCommandLine: ?[*:0]u16,
    lpProcessAttributes: ?*SECURITY_ATTRIBUTES,
    lpThreadAttributes: ?*SECURITY_ATTRIBUTES,
    bInheritHandles: BOOL,
    dwCreationFlags: DWORD,
    lpEnvironment: ?*anyopaque,
    lpCurrentDirectory: ?[*:0]const u16,
    lpStartupInfo: *windows.STARTUPINFOW,
    lpProcessInformation: *windows.PROCESS_INFORMATION,
) callconv(.winapi) BOOL;

extern "kernel32" fn PeekNamedPipe(
    hNamedPipe: HANDLE,
    lpBuffer: ?*anyopaque,
    nBufferSize: DWORD,
    lpBytesRead: ?*DWORD,
    lpTotalBytesAvail: ?*DWORD,
    lpBytesLeftThisMessage: ?*DWORD,
) callconv(.winapi) BOOL;

extern "kernel32" fn ReadFile(
    hFile: HANDLE,
    lpBuffer: [*]u8,
    nNumberOfBytesToRead: DWORD,
    lpNumberOfBytesRead: *DWORD,
    lpOverlapped: ?*windows.OVERLAPPED,
) callconv(.winapi) BOOL;

extern "kernel32" fn WriteFile(
    hFile: HANDLE,
    lpBuffer: [*]const u8,
    nNumberOfBytesToWrite: DWORD,
    lpNumberOfBytesWritten: *DWORD,
    lpOverlapped: ?*windows.OVERLAPPED,
) callconv(.winapi) BOOL;

extern "kernel32" fn WaitForSingleObject(hHandle: HANDLE, dwMilliseconds: DWORD) callconv(.winapi) DWORD;

extern "kernel32" fn GetExitCodeProcess(hProcess: HANDLE, lpExitCode: *DWORD) callconv(.winapi) BOOL;

extern "kernel32" fn CreateJobObjectW(
    lpJobAttributes: ?*SECURITY_ATTRIBUTES,
    lpName: ?[*:0]const u16,
) callconv(.winapi) ?HANDLE;

extern "kernel32" fn SetInformationJobObject(
    hJob: HANDLE,
    JobObjectInfoClass: DWORD,
    lpJobObjectInfo: *anyopaque,
    cbJobObjectInfoLength: DWORD,
) callconv(.winapi) BOOL;

extern "kernel32" fn AssignProcessToJobObject(hJob: HANDLE, hProcess: HANDLE) callconv(.winapi) BOOL;

threadlocal var g_controllers: std.ArrayListUnmanaged(*TmuxController) = .empty;

const INITIAL_BACKOFF_MS: i64 = 500;
const MAX_BACKOFF_MS: i64 = 5000;

const RawTransport = struct {
    stdin_write: HANDLE = INVALID_HANDLE_VALUE,
    stdout_read: HANDLE = INVALID_HANDLE_VALUE,
    process: HANDLE = INVALID_HANDLE_VALUE,
    thread: HANDLE = INVALID_HANDLE_VALUE,
    job: ?HANDLE = null,

    fn start(alloc: Allocator, command: pty_command.CommandLine, password: []const u8) !RawTransport {
        var self: RawTransport = .{};
        errdefer self.deinit();

        var child_stdin_read: HANDLE = INVALID_HANDLE_VALUE;
        var child_stdout_write: HANDLE = INVALID_HANDLE_VALUE;
        const inherit_sa = SECURITY_ATTRIBUTES{
            .nLength = @sizeOf(SECURITY_ATTRIBUTES),
            .lpSecurityDescriptor = null,
            .bInheritHandle = windows.TRUE,
        };

        if (CreatePipe(&child_stdin_read, &self.stdin_write, &inherit_sa, 0) == 0) return error.CreatePipeFailed;
        errdefer if (child_stdin_read != INVALID_HANDLE_VALUE) windows.CloseHandle(child_stdin_read);
        if (CreatePipe(&self.stdout_read, &child_stdout_write, &inherit_sa, 0) == 0) return error.CreatePipeFailed;
        errdefer if (child_stdout_write != INVALID_HANDLE_VALUE) windows.CloseHandle(child_stdout_write);

        _ = SetHandleInformation(self.stdin_write, handle_flag_inherit, 0);
        _ = SetHandleInformation(self.stdout_read, handle_flag_inherit, 0);

        var startup_info = std.mem.zeroes(windows.STARTUPINFOW);
        startup_info.cb = @sizeOf(windows.STARTUPINFOW);
        startup_info.dwFlags = startf_use_std_handles;
        startup_info.hStdInput = child_stdin_read;
        startup_info.hStdOutput = child_stdout_write;
        startup_info.hStdError = child_stdout_write;

        const cmd_buf = try alloc.alloc(u16, command.len + 1);
        defer alloc.free(cmd_buf);
        @memcpy(cmd_buf[0..command.len], command);
        cmd_buf[command.len] = 0;

        var askpass_path: ?[]const u8 = null;
        defer if (askpass_path) |path| alloc.free(path);
        var env_map: ?std.process.EnvMap = null;
        defer if (env_map) |*map| map.deinit();
        var env_block: ?[]u16 = null;
        defer if (env_block) |block| alloc.free(block);

        if (password.len > 0) {
            askpass_path = platform_process.ensureSshAskPassScript(alloc) orelse return error.SshAskPassUnavailable;
            env_map = try std.process.getEnvMap(alloc);
            if (env_map) |*map| {
                try map.put("SSH_ASKPASS", askpass_path.?);
                try map.put("SSH_ASKPASS_REQUIRE", "force");
                try map.put("DISPLAY", "wispterm");
                try map.put("WISPTERM_SSH_PASSWORD", password);
                env_block = try std.process.createWindowsEnvBlock(alloc, map);
            }
        }
        const env_ptr: ?*anyopaque = if (env_block) |block| @ptrCast(block.ptr) else null;

        var proc_info: windows.PROCESS_INFORMATION = undefined;
        if (CreateProcessW(
            null,
            @ptrCast(cmd_buf.ptr),
            null,
            null,
            windows.TRUE,
            create_no_window | create_unicode_environment,
            env_ptr,
            null,
            &startup_info,
            &proc_info,
        ) == 0) return error.CreateProcessFailed;

        self.process = proc_info.hProcess;
        self.thread = proc_info.hThread;
        self.attachKillOnCloseJob();
        windows.CloseHandle(child_stdin_read);
        child_stdin_read = INVALID_HANDLE_VALUE;
        windows.CloseHandle(child_stdout_write);
        child_stdout_write = INVALID_HANDLE_VALUE;
        return self;
    }

    fn attachKillOnCloseJob(self: *RawTransport) void {
        const job = CreateJobObjectW(null, null) orelse return;
        var info = std.mem.zeroes(JOBOBJECT_EXTENDED_LIMIT_INFORMATION);
        info.BasicLimitInformation.LimitFlags = job_object_limit_kill_on_job_close;
        if (SetInformationJobObject(
            job,
            job_object_extended_limit_information,
            @ptrCast(&info),
            @sizeOf(JOBOBJECT_EXTENDED_LIMIT_INFORMATION),
        ) == 0) {
            windows.CloseHandle(job);
            return;
        }
        if (AssignProcessToJobObject(job, self.process) == 0) {
            windows.CloseHandle(job);
            return;
        }
        self.job = job;
    }

    fn deinit(self: *RawTransport) void {
        if (self.stdin_write != INVALID_HANDLE_VALUE) {
            windows.CloseHandle(self.stdin_write);
            self.stdin_write = INVALID_HANDLE_VALUE;
        }
        if (self.process != INVALID_HANDLE_VALUE) {
            const result = WaitForSingleObject(self.process, 250);
            if (result == wait_timeout) {
                windows.TerminateProcess(self.process, 1) catch {};
                _ = WaitForSingleObject(self.process, 1000);
            }
        }
        if (self.stdout_read != INVALID_HANDLE_VALUE) {
            windows.CloseHandle(self.stdout_read);
            self.stdout_read = INVALID_HANDLE_VALUE;
        }
        if (self.thread != INVALID_HANDLE_VALUE) {
            windows.CloseHandle(self.thread);
            self.thread = INVALID_HANDLE_VALUE;
        }
        if (self.process != INVALID_HANDLE_VALUE) {
            windows.CloseHandle(self.process);
            self.process = INVALID_HANDLE_VALUE;
        }
        if (self.job) |job| {
            windows.CloseHandle(job);
            self.job = null;
        }
    }

    fn outputAvailable(self: *RawTransport) ?usize {
        if (self.stdout_read == INVALID_HANDLE_VALUE) return null;
        var available: DWORD = 0;
        if (PeekNamedPipe(self.stdout_read, null, 0, null, &available, null) == 0) return null;
        return @intCast(available);
    }

    fn readOutput(self: *RawTransport, buffer: []u8) ?usize {
        if (self.stdout_read == INVALID_HANDLE_VALUE or buffer.len == 0) return null;
        var bytes_read: DWORD = 0;
        const to_read: DWORD = @intCast(@min(buffer.len, std.math.maxInt(DWORD)));
        if (ReadFile(self.stdout_read, buffer.ptr, to_read, &bytes_read, null) == 0) return null;
        return @intCast(bytes_read);
    }

    fn writeInput(self: *RawTransport, data: []const u8) void {
        if (self.stdin_write == INVALID_HANDLE_VALUE) return;
        var offset: usize = 0;
        while (offset < data.len) {
            const chunk_len: DWORD = @intCast(@min(data.len - offset, std.math.maxInt(DWORD)));
            var bytes_written: DWORD = 0;
            if (WriteFile(self.stdin_write, data[offset..].ptr, chunk_len, &bytes_written, null) == 0) return;
            if (bytes_written == 0) return;
            offset += @intCast(bytes_written);
        }
    }

    fn exited(self: *RawTransport) bool {
        if (self.process == INVALID_HANDLE_VALUE) return true;
        const result = WaitForSingleObject(self.process, 0);
        if (result == wait_timeout) return false;
        if (result != wait_object_0) return false;
        var exit_code: DWORD = 0;
        _ = GetExitCodeProcess(self.process, &exit_code);
        return true;
    }
};

pub const TmuxController = struct {
    alloc: Allocator,
    transport: RawTransport,
    bridge: *TmuxBridge,
    ssh_cmd: []u8,
    profile_name: []u8,
    password: [256]u8 = undefined,
    password_len: usize = 0,
    password_sent: bool = false,
    early: [4096]u8 = undefined,
    early_len: usize = 0,
    handshake_seen: bool = false,
    handshake_tail: [handshake_tail_max]u8 = undefined,
    handshake_tail_len: usize = 0,
    early_debug_chunks: u8 = 0,
    last_cols: u16 = 0,
    last_rows: u16 = 0,
    reconnecting: bool = false,
    next_retry_ms: i64 = 0,
    backoff_ms: i64 = INITIAL_BACKOFF_MS,

    fn tick(self: *TmuxController, client_cols: u16, client_rows: u16) void {
        if (self.reconnecting) {
            self.tryReconnect();
            return;
        }

        var buf: [16384]u8 = undefined;
        var reads: usize = 0;
        while (reads < 64) : (reads += 1) {
            const available = self.transport.outputAvailable() orelse {
                self.markDisconnected();
                return;
            };
            if (available == 0) break;
            const to_read = @min(buf.len, available);
            const n = self.transport.readOutput(buf[0..to_read]) orelse {
                self.markDisconnected();
                return;
            };
            if (n == 0) {
                self.markDisconnected();
                return;
            }
            const chunk = buf[0..n];
            self.maybeInjectPassword(chunk);
            const handshake = !self.handshake_seen and self.observeHandshake(chunk);
            if (!self.handshake_seen and !handshake) self.logPreHandshakeOutput(chunk);
            if (handshake) {
                self.handshake_seen = true;
                self.backoff_ms = INITIAL_BACKOFF_MS;
                std.debug.print("tmux: control-mode handshake seen\n", .{});
            }
            self.bridge.session.feed(chunk) catch {};
        }

        if (self.transportExited()) {
            self.markDisconnected();
            return;
        }

        if (!self.handshake_seen) return;

        self.syncSize(client_cols, client_rows);
        self.bridge.panes.pumpKeystrokes(&self.bridge.session) catch {};
        const cmds = self.bridge.session.pendingCommands();
        if (cmds.len > 0) {
            self.transport.writeInput(cmds);
            self.bridge.session.clearCommands();
        }
    }

    fn transportExited(self: *TmuxController) bool {
        return self.transport.exited();
    }

    fn markDisconnected(self: *TmuxController) void {
        if (self.reconnecting) return;
        std.debug.print("tmux: transport lost - reconnecting...\n", .{});
        self.transport.deinit();
        self.handshake_seen = false;
        self.password_sent = false;
        self.early_len = 0;
        self.handshake_tail_len = 0;
        self.early_debug_chunks = 0;
        self.last_cols = 0;
        self.last_rows = 0;
        self.bridge.session.resetForReconnect();
        self.reconnecting = true;
        self.next_retry_ms = std.time.milliTimestamp() + self.backoff_ms;
    }

    fn tryReconnect(self: *TmuxController) void {
        if (std.time.milliTimestamp() < self.next_retry_ms) return;

        const owned = pty_command.allocCommandLineFromUtf8(self.alloc, self.ssh_cmd) catch {
            self.scheduleRetry();
            return;
        };
        defer pty_command.freeCommandLine(self.alloc, owned);

        const transport = RawTransport.start(self.alloc, pty_command.commandLineFromOwned(owned), self.password[0..self.password_len]) catch {
            self.scheduleRetry();
            return;
        };

        self.transport = transport;
        self.bridge.session.start() catch {};
        self.reconnecting = false;
        std.debug.print("tmux: reconnect transport spawned\n", .{});
    }

    fn scheduleRetry(self: *TmuxController) void {
        self.backoff_ms = @min(self.backoff_ms * 2, MAX_BACKOFF_MS);
        self.next_retry_ms = std.time.milliTimestamp() + self.backoff_ms;
    }

    fn maybeInjectPassword(self: *TmuxController, chunk: []const u8) void {
        if (self.password_sent or self.password_len == 0) return;
        const space = self.early.len - self.early_len;
        const take = @min(space, chunk.len);
        @memcpy(self.early[self.early_len..][0..take], chunk[0..take]);
        self.early_len += take;
        if (std.mem.indexOf(u8, self.early[0..self.early_len], "assword") != null) {
            self.transport.writeInput(self.password[0..self.password_len]);
            self.transport.writeInput("\n");
            self.password_sent = true;
        }
    }

    fn observeHandshake(self: *TmuxController, chunk: []const u8) bool {
        const in_chunk = std.mem.indexOf(u8, chunk, control_mode_handshake) != null;
        var probe: [handshake_tail_max + control_mode_handshake.len]u8 = undefined;
        const take = @min(chunk.len, control_mode_handshake.len);
        @memcpy(probe[0..self.handshake_tail_len], self.handshake_tail[0..self.handshake_tail_len]);
        @memcpy(probe[self.handshake_tail_len..][0..take], chunk[0..take]);
        const in_boundary = std.mem.indexOf(u8, probe[0 .. self.handshake_tail_len + take], control_mode_handshake) != null;
        self.updateHandshakeTail(chunk);
        return in_chunk or in_boundary;
    }

    fn updateHandshakeTail(self: *TmuxController, chunk: []const u8) void {
        if (chunk.len >= handshake_tail_max) {
            @memcpy(self.handshake_tail[0..handshake_tail_max], chunk[chunk.len - handshake_tail_max ..]);
            self.handshake_tail_len = handshake_tail_max;
            return;
        }

        var combined: [handshake_tail_max * 2]u8 = undefined;
        @memcpy(combined[0..self.handshake_tail_len], self.handshake_tail[0..self.handshake_tail_len]);
        @memcpy(combined[self.handshake_tail_len..][0..chunk.len], chunk);
        const total = self.handshake_tail_len + chunk.len;
        const keep = @min(total, handshake_tail_max);
        @memcpy(self.handshake_tail[0..keep], combined[total - keep ..][0..keep]);
        self.handshake_tail_len = keep;
    }

    fn logPreHandshakeOutput(self: *TmuxController, chunk: []const u8) void {
        if (self.early_debug_chunks >= 6) return;
        self.early_debug_chunks += 1;

        var rendered: [512]u8 = undefined;
        var pos: usize = 0;
        const limit = @min(chunk.len, 220);
        for (chunk[0..limit]) |b| {
            const text = switch (b) {
                '\r' => "\\r",
                '\n' => "\\n",
                '\t' => "\\t",
                0x1b => "<ESC>",
                else => null,
            };
            if (text) |s| {
                if (pos + s.len > rendered.len) break;
                @memcpy(rendered[pos..][0..s.len], s);
                pos += s.len;
            } else if (b >= 0x20 and b < 0x7f) {
                if (pos + 1 > rendered.len) break;
                rendered[pos] = b;
                pos += 1;
            } else {
                if (pos + 1 > rendered.len) break;
                rendered[pos] = '.';
                pos += 1;
            }
        }
        const suffix = if (chunk.len > limit) "..." else "";
        std.debug.print("tmux: pre-handshake output ({d} bytes): {s}{s}\n", .{ chunk.len, rendered[0..pos], suffix });
    }

    fn syncSize(self: *TmuxController, cols: u16, rows: u16) void {
        if (cols == 0 or rows == 0) return;
        if (cols == self.last_cols and rows == self.last_rows) return;
        self.last_cols = cols;
        self.last_rows = rows;
        self.bridge.session.resizeClient(cols, rows) catch {};
    }

    fn destroy(self: *TmuxController) void {
        if (!self.reconnecting) {
            self.transport.deinit();
        }
        self.bridge.destroy();
        self.alloc.free(self.ssh_cmd);
        self.alloc.free(self.profile_name);
        self.alloc.destroy(self);
    }

    fn reviveOrFocus(self: *TmuxController) bool {
        self.bridge.pruneDetachedPanes();
        if (self.bridge.focusFirstTab()) return true;
        self.bridge.session.start() catch return false;
        return true;
    }
};

pub fn start(
    alloc: Allocator,
    ssh_cmd_utf8: []const u8,
    password: []const u8,
    profile_name: []const u8,
    cols: u16,
    rows: u16,
    scrollback_limit: u32,
    cursor_style: Config.CursorStyle,
    cursor_blink: bool,
) bool {
    if (profile_name.len > 0) {
        for (g_controllers.items) |controller| {
            if (std.mem.eql(u8, controller.profile_name, profile_name)) {
                if (controller.reviveOrFocus()) {
                    std.debug.print("tmux: profile '{s}' already active; reused controller\n", .{profile_name});
                    return true;
                }
                std.debug.print("tmux: profile '{s}' already active but revive failed\n", .{profile_name});
                return false;
            }
        }
    }

    const owned = pty_command.allocCommandLineFromUtf8(alloc, ssh_cmd_utf8) catch return false;
    defer pty_command.freeCommandLine(alloc, owned);

    std.debug.print("tmux: launching transport: {s}\n", .{ssh_cmd_utf8});
    var transport = RawTransport.start(alloc, pty_command.commandLineFromOwned(owned), password) catch |err| {
        std.debug.print("tmux: startCommand failed: {}\n", .{err});
        return false;
    };

    const bridge = TmuxBridge.create(alloc, cols, rows, scrollback_limit, cursor_style, cursor_blink) catch {
        transport.deinit();
        return false;
    };
    bridge.session.start() catch {
        bridge.destroy();
        transport.deinit();
        return false;
    };

    const ssh_cmd_dup = alloc.dupe(u8, ssh_cmd_utf8) catch {
        bridge.destroy();
        transport.deinit();
        return false;
    };
    const profile_dup = alloc.dupe(u8, profile_name) catch {
        alloc.free(ssh_cmd_dup);
        bridge.destroy();
        transport.deinit();
        return false;
    };

    const self = alloc.create(TmuxController) catch {
        alloc.free(profile_dup);
        alloc.free(ssh_cmd_dup);
        bridge.destroy();
        transport.deinit();
        return false;
    };
    self.* = .{ .alloc = alloc, .transport = transport, .bridge = bridge, .ssh_cmd = ssh_cmd_dup, .profile_name = profile_dup };
    const plen = @min(password.len, self.password.len);
    @memcpy(self.password[0..plen], password[0..plen]);
    self.password_len = plen;

    g_controllers.append(alloc, self) catch {
        self.destroy();
        return false;
    };
    std.debug.print("tmux: controller started ({d} active)\n", .{g_controllers.items.len});
    return true;
}

pub fn tickAll(alloc: Allocator, client_cols: u16, client_rows: u16) void {
    _ = alloc;
    for (g_controllers.items) |c| c.tick(client_cols, client_rows);
}

pub fn shutdownAll(alloc: Allocator) void {
    for (g_controllers.items) |c| c.destroy();
    g_controllers.deinit(alloc);
    g_controllers = .empty;
}

pub fn forgetClosedTab(tab_state: *anyopaque) void {
    const t: *tab.TabState = @ptrCast(@alignCast(tab_state));
    for (g_controllers.items) |c| {
        if (c.bridge.forgetTab(t)) return;
    }
}

pub fn anyActive() bool {
    return g_controllers.items.len > 0;
}

pub fn activeProfileNames(alloc: Allocator) []const []const u8 {
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    for (g_controllers.items) |c| {
        if (c.profile_name.len == 0) continue;
        var dup = false;
        for (names.items) |n| {
            if (std.mem.eql(u8, n, c.profile_name)) {
                dup = true;
                break;
            }
        }
        if (dup) continue;
        const copy = alloc.dupe(u8, c.profile_name) catch continue;
        names.append(alloc, copy) catch continue;
    }
    return names.toOwnedSlice(alloc) catch &.{};
}

pub fn requestSplit(surface: *anyopaque, horizontal: bool) bool {
    const dir: layout.Dir = if (horizontal) .horizontal else .vertical;
    for (g_controllers.items) |c| {
        if (c.bridge.panes.findIdBySurface(surface)) |pane_id| {
            c.bridge.session.splitPane(pane_id, dir) catch return false;
            return true;
        }
    }
    return false;
}

pub fn requestClosePane(surface: *anyopaque) bool {
    for (g_controllers.items) |c| {
        if (c.bridge.panes.findIdBySurface(surface)) |pane_id| {
            c.bridge.session.killPane(pane_id) catch return false;
            return true;
        }
    }
    return false;
}
