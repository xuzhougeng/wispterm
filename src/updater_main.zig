const std = @import("std");
const updater_core = @import("updater_core.zig");

const windows = std.os.windows;

const SYNCHRONIZE: u32 = 0x00100000;
const WAIT_OBJECT_0: u32 = 0x00000000;
const WAIT_TIMEOUT: u32 = 0x00000102;
const WAIT_FAILED: u32 = 0xFFFFFFFF;
const WAIT_MS: u32 = 60_000;

extern "kernel32" fn OpenProcess(dwDesiredAccess: u32, bInheritHandle: windows.BOOL, dwProcessId: u32) callconv(.winapi) ?windows.HANDLE;
extern "kernel32" fn WaitForSingleObject(hHandle: windows.HANDLE, dwMilliseconds: u32) callconv(.winapi) u32;

const Win32Diagnostic = struct {
    operation: []const u8,
    code: windows.Win32Error,
    wait_result: ?u32 = null,
};

const RunContext = struct {
    stage: []const u8 = "startup",
    win32: ?Win32Diagnostic = null,

    fn setStage(self: *RunContext, stage: []const u8) void {
        self.stage = stage;
        self.win32 = null;
    }

    fn setWin32(self: *RunContext, operation: []const u8, code: windows.Win32Error, wait_result: ?u32) void {
        self.win32 = .{
            .operation = operation,
            .code = code,
            .wait_result = wait_result,
        };
    }
};

fn waitForPid(pid: u32, ctx: *RunContext) !void {
    const handle = OpenProcess(SYNCHRONIZE, 0, pid) orelse {
        const err = windows.GetLastError();
        ctx.setWin32("OpenProcess", err, null);
        if (err == .INVALID_PARAMETER) return;
        return error.OpenProcessFailed;
    };
    defer windows.CloseHandle(handle);

    const rc = WaitForSingleObject(handle, WAIT_MS);
    if (rc == WAIT_TIMEOUT) return error.WaitTimedOut;
    if (rc != WAIT_OBJECT_0) {
        ctx.setWin32("WaitForSingleObject", windows.GetLastError(), rc);
        if (rc == WAIT_FAILED) return error.WaitFailed;
        return error.UnexpectedWaitResult;
    }
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

fn logFailure(allocator: std.mem.Allocator, ctx: RunContext, err: anyerror) !void {
    const appdata = try std.fs.getAppDataDir(allocator, "Phantty");
    defer allocator.free(appdata);

    const log_dir = try std.fs.path.join(allocator, &.{ appdata, "logs" });
    defer allocator.free(log_dir);
    try std.fs.cwd().makePath(log_dir);

    const log_path = try std.fs.path.join(allocator, &.{ log_dir, "phantty-updater.log" });
    defer allocator.free(log_path);

    var file = try std.fs.createFileAbsolute(log_path, .{ .truncate = false });
    defer file.close();
    try file.seekFromEnd(0);

    if (ctx.win32) |diag| {
        const line = try std.fmt.allocPrint(
            allocator,
            "stage={s} error={} win32_operation={s} win32_error={} win32_error_code={d} wait_result={?d}\n",
            .{ ctx.stage, err, diag.operation, diag.code, @intFromEnum(diag.code), diag.wait_result },
        );
        defer allocator.free(line);
        try file.writeAll(line);
    } else {
        const line = try std.fmt.allocPrint(allocator, "stage={s} error={}\n", .{ ctx.stage, err });
        defer allocator.free(line);
        try file.writeAll(line);
    }
}

fn run(allocator: std.mem.Allocator, ctx: *RunContext) !void {
    ctx.setStage("parse arguments");

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const options = updater_core.parseArgs(args[1..]) catch |err| {
        std.debug.print("phantty-updater: invalid arguments: {}\n", .{err});
        return err;
    };

    ctx.setStage("wait for Phantty process");
    try waitForPid(options.pid, ctx);

    ctx.setStage("replace payload");
    try updater_core.replacePayload(allocator, options.source, options.target);

    ctx.setStage("restart Phantty");
    if (options.restart) try relaunch(allocator, options.target);
}

pub fn main() void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var ctx: RunContext = .{};
    run(allocator, &ctx) catch |err| {
        std.debug.print("phantty-updater: stage={s} error={}\n", .{ ctx.stage, err });
        if (ctx.win32) |diag| {
            std.debug.print(
                "phantty-updater: {s} GetLastError={} ({d}) wait_result={?d}\n",
                .{ diag.operation, diag.code, @intFromEnum(diag.code), diag.wait_result },
            );
        }
        logFailure(allocator, ctx, err) catch |log_err| {
            std.debug.print("phantty-updater: failed to write log: {}\n", .{log_err});
        };
        std.process.exit(1);
    };
}
