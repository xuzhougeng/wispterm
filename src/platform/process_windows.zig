const std = @import("std");
const shared = @import("process_shared.zig");

pub fn currentProcessId() u32 {
    return GetCurrentProcessId();
}

pub fn waitForPid(pid: u32, timeout_ms: u32, diagnostic: ?*shared.WaitForPidDiagnostic) !void {
    const windows = std.os.windows;
    const handle = OpenProcess(windows_synchronize, 0, pid) orelse {
        const err = windows.GetLastError();
        setWaitDiagnostic(diagnostic, "OpenProcess", @intFromEnum(err), null);
        if (err == .INVALID_PARAMETER) return;
        return error.OpenProcessFailed;
    };
    defer windows.CloseHandle(handle);

    const rc = WaitForSingleObject(handle, timeout_ms);
    if (rc == windows_wait_timeout) return error.WaitTimedOut;
    if (rc != windows_wait_object_0) {
        setWaitDiagnostic(diagnostic, "WaitForSingleObject", @intFromEnum(windows.GetLastError()), rc);
        if (rc == windows_wait_failed) return error.WaitFailed;
        return error.UnexpectedWaitResult;
    }
}

pub fn childExited(id: std.process.Child.Id, timeout_ms: u32) shared.ChildExit {
    const windows = std.os.windows;
    windows.WaitForSingleObject(id, timeout_ms) catch |err| switch (err) {
        error.WaitTimeOut => return .running,
        else => return .gone,
    };
    // The process object is not consumed by WaitForSingleObject, so the caller's
    // std.process.Child.wait() still closes the handle later — we only report
    // the code here. (On Windows, callers must NOT pre-set Child.term, or the
    // process handle would leak.)
    var code: u32 = 0;
    if (GetExitCodeProcess(id, &code) == 0) return .gone;
    return .{ .exited = code };
}

pub fn terminateChild(id: std.process.Child.Id) void {
    const windows = std.os.windows;
    windows.TerminateProcess(id, 1) catch {};
}

pub fn processCwd(allocator: std.mem.Allocator, pid: i32) ?[]u8 {
    // Windows resolves local relative preview paths via OSC 7 (pwsh shell
    // integration), so a process-cwd query isn't needed here.
    _ = allocator;
    _ = pid;
    return null;
}

pub fn writeAllToPipe(file: std.fs.File, data: []const u8) shared.PipeWriteError!void {
    const windows = std.os.windows;
    var index: usize = 0;
    while (index < data.len) {
        var written: windows.DWORD = 0;
        const remaining = data[index..];
        const chunk_len: windows.DWORD = @intCast(@min(remaining.len, std.math.maxInt(windows.DWORD)));
        if (windows.kernel32.WriteFile(file.handle, remaining.ptr, chunk_len, &written, null) == 0) {
            return switch (windows.GetLastError()) {
                .BROKEN_PIPE, .NO_DATA => error.BrokenPipe,
                else => error.WriteFailed,
            };
        }
        if (written == 0) return error.BrokenPipe;
        index += written;
    }
}

pub fn spawnDetachedWithOptions(allocator: std.mem.Allocator, options: shared.DetachedSpawnOptions) !void {
    const child = try allocator.create(std.process.Child);
    errdefer allocator.destroy(child);

    child.* = std.process.Child.init(options.argv, allocator);
    child.cwd = options.cwd;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.create_no_window = options.create_no_window;
    try child.spawn();

    const windows = std.os.windows;
    windows.CloseHandle(child.id);
    windows.CloseHandle(child.thread_handle);
    allocator.destroy(child);
}

const windows_synchronize: u32 = 0x00100000;
const windows_wait_object_0: u32 = 0x00000000;
const windows_wait_timeout: u32 = 0x00000102;
const windows_wait_failed: u32 = 0xFFFFFFFF;

extern "kernel32" fn OpenProcess(
    dwDesiredAccess: u32,
    bInheritHandle: std.os.windows.BOOL,
    dwProcessId: u32,
) callconv(.winapi) ?std.os.windows.HANDLE;

extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;

extern "kernel32" fn WaitForSingleObject(
    hHandle: std.os.windows.HANDLE,
    dwMilliseconds: u32,
) callconv(.winapi) u32;

extern "kernel32" fn GetExitCodeProcess(
    hProcess: std.os.windows.HANDLE,
    lpExitCode: *u32,
) callconv(.winapi) i32;

fn setWaitDiagnostic(diagnostic: ?*shared.WaitForPidDiagnostic, operation: []const u8, code: u32, wait_result: ?u32) void {
    if (diagnostic) |diag| {
        diag.* = .{
            .operation = operation,
            .code = code,
            .wait_result = wait_result,
        };
    }
}
