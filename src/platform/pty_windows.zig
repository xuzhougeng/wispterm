const std = @import("std");
const pty_command = @import("pty_command.zig");
const pty_command_windows = @import("pty_command_windows.zig");

const windows = std.os.windows;
const HANDLE = windows.HANDLE;
const INVALID_HANDLE_VALUE = windows.INVALID_HANDLE_VALUE;
const DWORD = windows.DWORD;
const BOOL = windows.BOOL;
const HRESULT = i32;
const PseudoConsoleHandle = windows.HANDLE;

const s_ok: HRESULT = 0;
const handle_flag_inherit: DWORD = 0x00000001;

const COORD = extern struct {
    X: i16,
    Y: i16,
};

const SECURITY_ATTRIBUTES = extern struct {
    nLength: DWORD,
    lpSecurityDescriptor: ?*anyopaque,
    bInheritHandle: BOOL,
};

extern "kernel32" fn SetHandleInformation(hObject: HANDLE, dwMask: DWORD, dwFlags: DWORD) callconv(.winapi) BOOL;

extern "kernel32" fn CreatePipe(
    hReadPipe: *HANDLE,
    hWritePipe: *HANDLE,
    lpPipeAttributes: ?*const SECURITY_ATTRIBUTES,
    nSize: DWORD,
) callconv(.winapi) BOOL;

extern "kernel32" fn CreatePseudoConsole(
    size: COORD,
    hInput: HANDLE,
    hOutput: HANDLE,
    dwFlags: DWORD,
    phPC: *PseudoConsoleHandle,
) callconv(.winapi) HRESULT;

extern "kernel32" fn ClosePseudoConsole(hPC: PseudoConsoleHandle) callconv(.winapi) void;

extern "kernel32" fn ResizePseudoConsole(hPC: PseudoConsoleHandle, size: COORD) callconv(.winapi) HRESULT;

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

extern "kernel32" fn PeekNamedPipe(
    hNamedPipe: HANDLE,
    lpBuffer: ?*anyopaque,
    nBufferSize: DWORD,
    lpBytesRead: ?*DWORD,
    lpTotalBytesAvail: ?*DWORD,
    lpBytesLeftThisMessage: ?*DWORD,
) callconv(.winapi) BOOL;

extern "kernel32" fn CancelIoEx(
    hFile: HANDLE,
    lpOverlapped: ?*windows.OVERLAPPED,
) callconv(.winapi) BOOL;

pub const ReadError = error{ ReadInterrupted, BrokenPipe, ReadFailed };
pub const WriteError = error{ BrokenPipe, WriteFailed };

pub const winsize = struct {
    ws_col: u16,
    ws_row: u16,
    ws_xpixel: u16 = 0,
    ws_ypixel: u16 = 0,
};

pub const Pty = struct {
    out_pipe: HANDLE,
    in_pipe: HANDLE,
    out_pipe_pty: HANDLE,
    in_pipe_pty: HANDLE,
    pseudo_console: PseudoConsoleHandle,
    size: winsize,

    pub fn open(size: winsize) !Pty {
        var self: Pty = undefined;
        self.size = size;

        if (CreatePipe(&self.out_pipe, &self.out_pipe_pty, null, 0) == 0) {
            return error.CreatePipeFailed;
        }
        errdefer {
            windows.CloseHandle(self.out_pipe);
            windows.CloseHandle(self.out_pipe_pty);
        }

        if (CreatePipe(&self.in_pipe_pty, &self.in_pipe, null, 0) == 0) {
            return error.CreatePipeFailed;
        }
        errdefer {
            windows.CloseHandle(self.in_pipe);
            windows.CloseHandle(self.in_pipe_pty);
        }

        _ = SetHandleInformation(self.out_pipe, handle_flag_inherit, 0);
        _ = SetHandleInformation(self.out_pipe_pty, handle_flag_inherit, 0);
        _ = SetHandleInformation(self.in_pipe, handle_flag_inherit, 0);
        _ = SetHandleInformation(self.in_pipe_pty, handle_flag_inherit, 0);

        const coord = COORD{ .X = @intCast(size.ws_col), .Y = @intCast(size.ws_row) };
        const hr = CreatePseudoConsole(coord, self.in_pipe_pty, self.out_pipe_pty, 0, &self.pseudo_console);
        if (hr != s_ok) return error.CreatePseudoConsoleFailed;

        return self;
    }

    pub fn deinit(self: *Pty) void {
        // Idempotent: every handle is cleared after release so a second deinit
        // (or a double cleanup path) cannot close an already-closed handle, which
        // on Windows corrupts the heap (STATUS_HEAP_CORRUPTION, 0xc0000374).
        if (self.pseudo_console != INVALID_HANDLE_VALUE) {
            ClosePseudoConsole(self.pseudo_console);
            self.pseudo_console = INVALID_HANDLE_VALUE;
        }
        if (self.out_pipe != INVALID_HANDLE_VALUE) {
            windows.CloseHandle(self.out_pipe);
            self.out_pipe = INVALID_HANDLE_VALUE;
        }
        if (self.in_pipe != INVALID_HANDLE_VALUE) {
            windows.CloseHandle(self.in_pipe);
            self.in_pipe = INVALID_HANDLE_VALUE;
        }
        if (self.out_pipe_pty != INVALID_HANDLE_VALUE) {
            windows.CloseHandle(self.out_pipe_pty);
            self.out_pipe_pty = INVALID_HANDLE_VALUE;
        }
        if (self.in_pipe_pty != INVALID_HANDLE_VALUE) {
            windows.CloseHandle(self.in_pipe_pty);
            self.in_pipe_pty = INVALID_HANDLE_VALUE;
        }
    }

    pub fn getSize(self: *const Pty) winsize {
        return self.size;
    }

    pub fn setSize(self: *Pty, s: winsize) !void {
        const coord = COORD{ .X = @intCast(s.ws_col), .Y = @intCast(s.ws_row) };
        const hr = ResizePseudoConsole(self.pseudo_console, coord);
        if (hr != s_ok) return error.ResizePseudoConsoleFailed;
        self.size = s;
    }

    pub fn startCommand(self: *Pty, command: *pty_command.Command, command_line: pty_command.CommandLine, cwd: pty_command.Cwd) !void {
        return pty_command_windows.startInPseudoConsole(command, self.pseudo_console, command_line, cwd);
    }

    pub fn readOutput(self: *Pty, buffer: []u8) ReadError!usize {
        if (buffer.len == 0) return 0;

        var bytes_read: DWORD = 0;
        const to_read: DWORD = @intCast(@min(buffer.len, std.math.maxInt(DWORD)));
        if (ReadFile(self.out_pipe, buffer.ptr, to_read, &bytes_read, null) == 0) {
            return switch (windows.GetLastError()) {
                .OPERATION_ABORTED => error.ReadInterrupted,
                .BROKEN_PIPE => error.BrokenPipe,
                else => error.ReadFailed,
            };
        }
        return @intCast(bytes_read);
    }

    pub fn writeInput(self: *Pty, data: []const u8) WriteError!void {
        var offset: usize = 0;
        while (offset < data.len) {
            const remaining = data.len - offset;
            const chunk_len: DWORD = @intCast(@min(remaining, std.math.maxInt(DWORD)));
            var bytes_written: DWORD = 0;

            if (WriteFile(
                self.in_pipe,
                data[offset..].ptr,
                chunk_len,
                &bytes_written,
                null,
            ) == 0) {
                return switch (windows.GetLastError()) {
                    .BROKEN_PIPE, .NO_DATA => error.BrokenPipe,
                    else => error.WriteFailed,
                };
            }
            if (bytes_written == 0) return error.BrokenPipe;
            offset += @intCast(bytes_written);
        }
    }

    pub fn outputAvailable(self: *Pty) ?usize {
        var available: DWORD = 0;
        if (PeekNamedPipe(self.out_pipe, null, 0, null, &available, null) == 0) return null;
        return @intCast(available);
    }

    pub fn cancelOutputRead(self: *Pty) void {
        _ = CancelIoEx(self.out_pipe, null);
    }
};

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
