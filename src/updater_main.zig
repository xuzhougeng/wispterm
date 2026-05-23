const std = @import("std");
const updater_core = @import("updater_core.zig");

const windows = std.os.windows;

const SYNCHRONIZE: u32 = 0x00100000;
const WAIT_OBJECT_0: u32 = 0x00000000;
const WAIT_TIMEOUT: u32 = 0x00000102;
const WAIT_MS: u32 = 60_000;

extern "kernel32" fn OpenProcess(dwDesiredAccess: u32, bInheritHandle: windows.BOOL, dwProcessId: u32) callconv(.winapi) ?windows.HANDLE;
extern "kernel32" fn WaitForSingleObject(hHandle: windows.HANDLE, dwMilliseconds: u32) callconv(.winapi) u32;

fn waitForPid(pid: u32) !void {
    const handle = OpenProcess(SYNCHRONIZE, 0, pid) orelse return;
    defer windows.CloseHandle(handle);

    const rc = WaitForSingleObject(handle, WAIT_MS);
    if (rc == WAIT_TIMEOUT) return error.WaitTimedOut;
    if (rc != WAIT_OBJECT_0) return error.WaitFailed;
}

fn relaunch(allocator: std.mem.Allocator, target: []const u8) !void {
    const exe = try updater_core.targetExePath(allocator, target);
    defer allocator.free(exe);

    const argv = [_][]const u8{exe};
    var child = std.process.Child.init(&argv, allocator);
    child.cwd = target;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.create_no_window = true;
    try child.spawn();
    windows.CloseHandle(child.id);
    windows.CloseHandle(child.thread_handle);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const options = updater_core.parseArgs(args[1..]) catch |err| {
        std.debug.print("phantty-updater: invalid arguments: {}\n", .{err});
        return err;
    };

    try waitForPid(options.pid);
    try updater_core.replacePayload(allocator, options.source, options.target);
    if (options.restart) try relaunch(allocator, options.target);
}
