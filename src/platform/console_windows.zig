const std = @import("std");

pub fn prepareCliConsole() void {
    _ = std.os.windows.GetStdHandle(std.os.windows.STD_OUTPUT_HANDLE) catch {
        const attach_parent_process: std.os.windows.DWORD = 0xFFFFFFFF;
        _ = AttachConsole(attach_parent_process);
    };
}

extern "kernel32" fn AttachConsole(dwProcessId: std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL;
