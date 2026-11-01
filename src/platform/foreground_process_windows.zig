//! Windows foreground-process query. A ConPTY has no foreground process
//! group, so this mirrors herdr's Windows strategy: snapshot the process
//! table (Toolhelp32), collect the descendants of the pane's shell, and
//! report the first one whose image name the caller recognizes. When no
//! descendant is recognized the deepest one is reported (so a seeded agent
//! identity survives an unknown wrapper such as `node.exe`); when the shell
//! has no descendants at all the shell itself is in the foreground.
//!
//! Limitations (documented in KNOWN_ISSUES.md): agents that run as a plain
//! `node.exe` / `python.exe` script cannot be named without reading the
//! remote process's command line, which this query deliberately does not do.

const std = @import("std");
const windows = std.os.windows;
const Pty = @import("pty.zig").Pty;
const Command = @import("pty_command.zig").Command;
const facade = @import("foreground_process.zig");

const DWORD = windows.DWORD;
const HANDLE = windows.HANDLE;
const BOOL = windows.BOOL;

const TH32CS_SNAPPROCESS: DWORD = 0x00000002;

const PROCESSENTRY32W = extern struct {
    dwSize: DWORD,
    cntUsage: DWORD,
    th32ProcessID: DWORD,
    th32DefaultHeapID: usize,
    th32ModuleID: DWORD,
    cntThreads: DWORD,
    th32ParentProcessID: DWORD,
    pcPriClassBase: windows.LONG,
    dwFlags: DWORD,
    szExeFile: [windows.MAX_PATH]u16,
};

extern "kernel32" fn CreateToolhelp32Snapshot(dwFlags: DWORD, th32ProcessID: DWORD) callconv(.winapi) HANDLE;
extern "kernel32" fn Process32FirstW(hSnapshot: HANDLE, lppe: *PROCESSENTRY32W) callconv(.winapi) BOOL;
extern "kernel32" fn Process32NextW(hSnapshot: HANDLE, lppe: *PROCESSENTRY32W) callconv(.winapi) BOOL;
extern "kernel32" fn GetProcessId(Process: HANDLE) callconv(.winapi) DWORD;

/// Upper bound on process-table entries examined per query.
const max_processes: usize = 4096;
const max_depth: u8 = 16;

const Entry = struct {
    pid: DWORD,
    parent: DWORD,
    exe: [windows.MAX_PATH]u16,
    depth: u8 = 0, // 0 = not a descendant of the shell
};

pub fn query(pty: *const Pty, command: *const Command, buf: []u8, recognizes: facade.Recognizer) ?facade.Info {
    if (pty.is_virtual) return null;
    if (command.process == windows.INVALID_HANDLE_VALUE) return null;
    const shell_pid = GetProcessId(command.process);
    if (shell_pid == 0) return null;

    const snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snapshot == windows.INVALID_HANDLE_VALUE) return null;
    defer windows.CloseHandle(snapshot);

    const entries = std.heap.page_allocator.alloc(Entry, max_processes) catch return null;
    defer std.heap.page_allocator.free(entries);
    var count: usize = 0;

    var pe: PROCESSENTRY32W = undefined;
    pe.dwSize = @sizeOf(PROCESSENTRY32W);
    if (Process32FirstW(snapshot, &pe) == 0) return null;
    while (true) {
        if (count < entries.len) {
            entries[count] = .{ .pid = pe.th32ProcessID, .parent = pe.th32ParentProcessID, .exe = pe.szExeFile };
            count += 1;
        }
        if (Process32NextW(snapshot, &pe) == 0) break;
    }
    const table = entries[0..count];

    // Mark descendants of the shell breadth-first by depth. PIDs are reused,
    // so a "parent" may be stale; the depth cap bounds any cycle.
    var depth: u8 = 1;
    var frontier_any = true;
    while (frontier_any and depth <= max_depth) : (depth += 1) {
        frontier_any = false;
        for (table) |*e| {
            if (e.depth != 0 or e.pid == shell_pid) continue;
            const parent_is_shell = depth == 1 and e.parent == shell_pid;
            var parent_marked = false;
            if (!parent_is_shell and depth > 1) {
                for (table) |p| if (p.pid == e.parent and p.depth == depth - 1) {
                    parent_marked = true;
                    break;
                };
            }
            if (parent_is_shell or parent_marked) {
                e.depth = depth;
                frontier_any = true;
            }
        }
    }

    var deepest: ?*const Entry = null;
    for (table) |*e| {
        if (e.depth == 0) continue;
        const name = exeName(e, buf) orelse continue;
        if (recognizes(name)) return .{ .name = name, .is_shell = false };
        if (deepest == null or e.depth > deepest.?.depth) deepest = e;
    }
    if (deepest) |e| {
        const name = exeName(e, buf) orelse "";
        return .{ .name = name, .is_shell = false };
    }
    return .{ .name = "", .is_shell = true };
}

fn exeName(e: *const Entry, buf: []u8) ?[]const u8 {
    const len = std.mem.indexOfScalar(u16, &e.exe, 0) orelse e.exe.len;
    const n = std.unicode.utf16LeToUtf8(buf, e.exe[0..len]) catch return null;
    return buf[0..n];
}
