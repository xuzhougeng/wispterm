//! wispterm-bench CLI runner. Builds the case set, applies `options.zig`
//! selection, runs each case through `Benchmark.run`, prints a human summary,
//! and writes a shareable JSON + Markdown report to the WispTerm config dir.
//! The bench binary links ghostty-vt for the TerminalStream case; this module
//! stays free of GUI/app dependencies.

const std = @import("std");
const Benchmark = @import("Benchmark.zig");
const options_mod = @import("options.zig");
const TerminalStream = @import("TerminalStream.zig");
const report = @import("report.zig");
const env = @import("env.zig");
const platform_dirs = @import("../platform/dirs.zig");

pub const CaseName = struct {
    name: []const u8,
    description: []const u8,
};

pub const all_cases = [_]CaseName{
    .{ .name = "terminal-stream", .description = "Synthetic VT byte stream through ghostty-vt (MB/s)" },
};

pub fn run(allocator: std.mem.Allocator, raw_args: []const []const u8) !void {
    var opts = try options_mod.parse(allocator, raw_args);
    defer opts.deinit();

    if (opts.help) {
        try stdoutAll(options_mod.USAGE);
        return;
    }
    if (opts.list) {
        try listCases(std.fs.File.stdout().deprecatedWriter());
        return;
    }

    const duration_ms: u64 = if (opts.duration_ms == 0) 1000 else opts.duration_ms;
    const mode: Benchmark.RunMode = .{ .duration = duration_ms * std.time.ns_per_ms };

    const stdout = std.fs.File.stdout().deprecatedWriter();
    try stdout.print(
        "wispterm-bench: duration={d}ms optimize={s}\n",
        .{ duration_ms, @tagName(@import("builtin").mode) },
    );

    var results: std.ArrayList(report.ScenarioResult) = .empty;
    defer {
        for (results.items) |r| allocator.free(r.name);
        results.deinit(allocator);
    }

    var any_ran = false;
    for (all_cases) |case| {
        if (opts.only) |only| {
            if (!std.mem.eql(u8, only, case.name)) continue;
        }
        if (try runCase(allocator, case, mode, stdout)) |sr| {
            try results.append(allocator, sr);
        }
        any_ran = true;
    }

    if (!any_ran) {
        try stdout.print("no benchmark case matched '{?s}'\n", .{opts.only});
        try listCases(stdout);
        return;
    }
    try stdout.writeAll("\n");

    try writeReport(allocator, results.items, stdout);
}

fn runCase(
    allocator: std.mem.Allocator,
    case: CaseName,
    mode: Benchmark.RunMode,
    w: anytype,
) !?report.ScenarioResult {
    if (std.mem.eql(u8, case.name, "terminal-stream")) {
        const ts = try TerminalStream.create(allocator, .{});
        defer ts.destroy();
        const bench = ts.benchmark();
        const result = try bench.run(mode);
        const mb_per_s: f64 = blk: {
            const bytes = @as(f64, @floatFromInt(@as(u64, result.iterations) * ts.bytesPerStep()));
            const secs = @as(f64, @floatFromInt(result.duration)) / @as(f64, @floatFromInt(std.time.ns_per_s));
            if (secs == 0) break :blk 0;
            break :blk bytes / (1024.0 * 1024.0) / secs;
        };
        try w.print(
            "  {s:<18} iters={d:>10}  {d:>8.2} MB/s   ({s})\n",
            .{ case.name, result.iterations, mb_per_s, case.description },
        );
        const duration_ms: u64 = @intCast(@divTrunc(result.duration, std.time.ns_per_ms));
        return .{
            .name = try allocator.dupe(u8, case.name),
            .unit = .throughput,
            .value = mb_per_s,
            .samples = result.iterations,
            .duration_ms = duration_ms,
        };
    }
    try w.print("  {s:<18} (not implemented)\n", .{case.name});
    return null;
}

fn writeReport(
    allocator: std.mem.Allocator,
    results: []const report.ScenarioResult,
    w: anytype,
) !void {
    const e = env.collect();
    const rep: report.Report = .{
        .app_version = e.app_version,
        .os = e.os,
        .cpu_arch = e.cpu_arch,
        .logical_cores = e.logical_cores,
        .runner = "cli",
        .backend = e.backend,
        .scenarios = results,
        .timestamp_ms = std.time.milliTimestamp(),
    };

    const json = try report.formatJson(allocator, rep);
    defer allocator.free(json);
    const md = try report.formatMarkdown(allocator, rep);
    defer allocator.free(md);

    if (writeReportFiles(allocator, json, md)) |paths| {
        try w.print("report written:\n  {s}\n  {s}\n\n", .{ paths.json_path, paths.md_path });
        allocator.free(paths.json_path);
        allocator.free(paths.md_path);
    } else |_| {
        try w.writeAll("report: could not write files to config dir; printing markdown only.\n\n");
    }
    // Always print the markdown so it can be pasted straight into a GitHub
    // issue/discussion even when file writing failed.
    try w.writeAll(md);
}

const ReportPaths = struct {
    json_path: []u8,
    md_path: []u8,
};

fn writeReportFiles(allocator: std.mem.Allocator, json: []const u8, md: []const u8) !ReportPaths {
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

fn listCases(w: anytype) !void {
    try w.writeAll("Available benchmark cases:\n");
    for (all_cases) |case| {
        try w.print("  {s:<18} {s}\n", .{ case.name, case.description });
    }
}

fn stdoutAll(s: []const u8) !void {
    try std.fs.File.stdout().deprecatedWriter().writeAll(s);
}

test "cli: all_cases lists terminal-stream" {
    try std.testing.expect(all_cases.len >= 1);
    var found = false;
    for (all_cases) |c| {
        if (std.mem.eql(u8, c.name, "terminal-stream")) found = true;
    }
    try std.testing.expect(found);
}
