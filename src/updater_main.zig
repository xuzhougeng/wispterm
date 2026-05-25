const std = @import("std");
const platform_process = @import("platform/process.zig");
const updater_core = @import("updater_core.zig");

const WAIT_MS: u32 = 60_000;

const RunContext = struct {
    stage: []const u8 = "startup",
    wait_diagnostic: ?platform_process.WaitForPidDiagnostic = null,

    fn setStage(self: *RunContext, stage: []const u8) void {
        self.stage = stage;
        self.wait_diagnostic = null;
    }
};

fn waitForPid(pid: u32, ctx: *RunContext) !void {
    var diagnostic: platform_process.WaitForPidDiagnostic = .{ .operation = "", .code = 0 };
    platform_process.waitForPid(pid, WAIT_MS, &diagnostic) catch |err| {
        if (diagnostic.operation.len > 0) ctx.wait_diagnostic = diagnostic;
        return err;
    };
}

fn relaunch(allocator: std.mem.Allocator, target: []const u8) !void {
    const exe = try updater_core.targetExePath(allocator, target);
    defer allocator.free(exe);

    const argv = [_][]const u8{exe};
    try platform_process.spawnDetachedWithOptions(allocator, .{
        .argv = &argv,
        .cwd = target,
        .create_no_window = true,
    });
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

    if (ctx.wait_diagnostic) |diag| {
        const line = try std.fmt.allocPrint(
            allocator,
            "stage={s} error={} os_operation={s} os_error_code={d} wait_result={?d}\n",
            .{ ctx.stage, err, diag.operation, diag.code, diag.wait_result },
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
        if (ctx.wait_diagnostic) |diag| {
            std.debug.print(
                "phantty-updater: {s} os_error_code={d} wait_result={?d}\n",
                .{ diag.operation, diag.code, diag.wait_result },
            );
        }
        logFailure(allocator, ctx, err) catch |log_err| {
            std.debug.print("phantty-updater: failed to write log: {}\n", .{log_err});
        };
        std.process.exit(1);
    };
}
