//! Shared benchmark report file I/O (app-side: links platform_dirs).
//!
//! Both the `wispterm-bench` CPU CLI (`cli.zig`) and the in-app GPU benchmark
//! driver (`driver.zig`) write reports to the WispTerm config dir in the same
//! shape, so a CLI run and an in-app run land side-by-side and stay comparable.
//! Extracted here (not in pure `report.zig`) because it needs `platform_dirs`.

const std = @import("std");
const platform_dirs = @import("../platform/dirs.zig");

pub const ReportPaths = struct {
    json_path: []u8,
    md_path: []u8,

    pub fn deinit(self: ReportPaths, allocator: std.mem.Allocator) void {
        allocator.free(self.json_path);
        allocator.free(self.md_path);
    }
};

/// Write `json` and `md` as `benchmark-report-<timestamp>.{json,md}` into the
/// WispTerm config dir, creating it if missing. Caller owns the returned paths.
pub fn writeReportFiles(allocator: std.mem.Allocator, json: []const u8, md: []const u8) !ReportPaths {
    const dir = try platform_dirs.configDir(allocator);
    defer allocator.free(dir);
    std.fs.cwd().makePath(dir) catch {};

    const ts = std.time.milliTimestamp();
    const json_name = try std.fmt.allocPrint(allocator, "benchmark-report-{d}.json", .{ts});
    defer allocator.free(json_name);
    const md_name = try std.fmt.allocPrint(allocator, "benchmark-report-{d}.md", .{ts});
    defer allocator.free(md_name);

    const json_path = try std.fs.path.join(allocator, &.{ dir, json_name });
    errdefer allocator.free(json_path);
    const md_path = try std.fs.path.join(allocator, &.{ dir, md_name });
    errdefer allocator.free(md_path);

    try std.fs.cwd().writeFile(.{ .sub_path = json_path, .data = json });
    try std.fs.cwd().writeFile(.{ .sub_path = md_path, .data = md });
    return .{ .json_path = json_path, .md_path = md_path };
}

/// Print a paste-ready Markdown report to stdout (always, even when file
/// writing fails) plus the paths of the written files (when it succeeded).
pub fn emitReport(allocator: std.mem.Allocator, json: []const u8, md: []const u8) !void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    if (writeReportFiles(allocator, json, md)) |paths| {
        var owned = paths;
        defer owned.deinit(allocator);
        try stdout.print("report written:\n  {s}\n  {s}\n\n", .{ paths.json_path, paths.md_path });
    } else |_| {
        try stdout.writeAll("report: could not write files to config dir; printing markdown only.\n\n");
    }
    try stdout.writeAll(md);
}
