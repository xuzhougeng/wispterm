//! Performance benchmark report schema + JSON/Markdown formatters.
//!
//! Pure formatter module: takes a `Report` value the caller assembles (env
//! fields + per-scenario results) and renders a machine-readable JSON blob and
//! a paste-ready GitHub Markdown table. No build_options or platform deps, so
//! it unit-tests in the fast suite. The in-app GPU benchmark (future M2) and
//! the `wispterm-bench` CLI both feed the same `Report` shape, so reports from
//! different machines and backends stay comparable.
//!
//! Field philosophy: optional in-app/GPU fields (`gpu_adapter`, `window`,
//! `dpi`, `grid`) are `?`-typed so a CLI run leaves them null and the formatter
//! omits them, while a future in-app run fills them. The shared scalar fields
//! (version, os, backend, cpu) are always present.

const std = @import("std");

pub const ScenarioUnit = enum {
    /// Per-second throughput (MB/s, iterations/s). `value` is the rate.
    throughput,
    /// Latency / frame time in nanoseconds. `p50`/`p95`/`max` apply.
    latency_ns,

    pub fn name(self: ScenarioUnit) []const u8 {
        return switch (self) {
            .throughput => "throughput",
            .latency_ns => "latency_ns",
        };
    }
};

pub const ScenarioResult = struct {
    name: []const u8,
    unit: ScenarioUnit,
    /// For throughput: the rate (MB/s etc.). For latency: mean frame ns.
    value: f64,
    /// Latency-only percentiles in ns; ignored for throughput.
    p50_ns: i64 = 0,
    p95_ns: i64 = 0,
    max_ns: i64 = 0,
    /// Wall-clock frames/iterations observed.
    samples: usize = 0,
    /// Run window in ms.
    duration_ms: u64 = 0,
};

pub const WindowInfo = struct {
    width_px: u32,
    height_px: u32,
    grid_cols: u32,
    grid_rows: u32,
    dpi: u32,
};

pub const GpuInfo = struct {
    /// "opengl" | "metal" | "d3d11" — the active renderer backend.
    backend: []const u8,
    /// Adapter/device description (DXGI description or Metal device name).
    adapter: []const u8,
    /// DXGI vendor id (Windows); 0 when not applicable.
    vendor_id: u32 = 0,
    device_id: u32 = 0,
};

pub const Report = struct {
    app_version: []const u8,
    os: []const u8,
    cpu_arch: []const u8,
    logical_cores: u32,
    /// "cli" for wispterm-bench, "in-app" for the future --benchmark mode.
    runner: []const u8,
    /// Always present (CLI derives it from build options; in-app from gpu.zig).
    backend: []const u8,
    gpu: ?GpuInfo = null,
    window: ?WindowInfo = null,
    scenarios: []const ScenarioResult = &.{},
    /// ISO-8601-ish timestamp the caller stamps (keeps this module pure/clockless).
    timestamp_ms: i64 = 0,
};

/// Render the report as a single-line JSON object (deterministic field order).
pub fn formatJson(allocator: std.mem.Allocator, r: Report) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    var w = buf.writer(allocator);
    try w.writeAll("{");
    try writeJsonField(&w, "app_version", r.app_version);
    try w.writeAll(",");
    try writeJsonField(&w, "os", r.os);
    try w.writeAll(",");
    try writeJsonField(&w, "cpu_arch", r.cpu_arch);
    try w.print(",\"logical_cores\":{d}", .{r.logical_cores});
    try w.writeAll(",");
    try writeJsonField(&w, "runner", r.runner);
    try w.writeAll(",");
    try writeJsonField(&w, "backend", r.backend);
    try w.print(",\"timestamp_ms\":{d}", .{r.timestamp_ms});

    if (r.gpu) |g| {
        try w.writeAll(",\"gpu\":{");
        try writeJsonField(&w, "backend", g.backend);
        try w.writeAll(",");
        try writeJsonField(&w, "adapter", g.adapter);
        try w.print(",\"vendor_id\":{d},\"device_id\":{d}}}", .{ g.vendor_id, g.device_id });
    }
    if (r.window) |win| {
        try w.print(",\"window\":{{\"width_px\":{d},\"height_px\":{d},\"grid_cols\":{d},\"grid_rows\":{d},\"dpi\":{d}}}", .{
            win.width_px, win.height_px, win.grid_cols, win.grid_rows, win.dpi,
        });
    }

    try w.writeAll(",\"scenarios\":[");
    for (r.scenarios, 0..) |s, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{");
        try writeJsonField(&w, "name", s.name);
        try w.writeAll(",");
        try writeJsonField(&w, "unit", s.unit.name());
        try w.print(",\"value\":{d}", .{s.value});
        if (s.unit == .latency_ns) {
            try w.print(",\"p50_ns\":{d},\"p95_ns\":{d},\"max_ns\":{d}", .{ s.p50_ns, s.p95_ns, s.max_ns });
        }
        try w.print(",\"samples\":{d},\"duration_ms\":{d}}}", .{ s.samples, s.duration_ms });
    }
    try w.writeAll("]}");

    return buf.toOwnedSlice(allocator);
}

/// Render a paste-ready GitHub Markdown summary (key=value table + scenario
/// table). Designed to be readable in an issue/comment.
pub fn formatMarkdown(allocator: std.mem.Allocator, r: Report) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    var w = buf.writer(allocator);
    try w.print("## WispTerm performance report\n\n", .{});
    try w.print("- **version:** {s}\n", .{r.app_version});
    try w.print("- **os:** {s}\n", .{r.os});
    try w.print("- **cpu:** {s} ({d} cores)\n", .{ r.cpu_arch, r.logical_cores });
    try w.print("- **backend:** {s}\n", .{r.backend});
    try w.print("- **runner:** {s}\n", .{r.runner});
    if (r.gpu) |g| {
        try w.print("- **gpu:** {s} - {s}", .{ g.backend, g.adapter });
        if (g.vendor_id != 0) try w.print(" (vendor={d}, device={d})", .{ g.vendor_id, g.device_id });
        try w.writeAll("\n");
    }
    if (r.window) |win| {
        try w.print("- **window:** {d}x{d} @ {d} DPI, grid {d}x{d}\n", .{
            win.width_px, win.height_px, win.dpi, win.grid_cols, win.grid_rows,
        });
    }
    try w.writeAll("\n| scenario | unit | value | fps | p50 | p95 | max | samples | duration_ms |\n");
    try w.writeAll("|---|---|---|---|---|---|---|---|---|\n");
    for (r.scenarios) |s| {
        const p50 = if (s.unit == .latency_ns) try std.fmt.allocPrint(allocator, "{d} ns", .{s.p50_ns}) else try allocator.dupe(u8, "-");
        defer allocator.free(p50);
        const p95 = if (s.unit == .latency_ns) try std.fmt.allocPrint(allocator, "{d} ns", .{s.p95_ns}) else try allocator.dupe(u8, "-");
        defer allocator.free(p95);
        const mx = if (s.unit == .latency_ns) try std.fmt.allocPrint(allocator, "{d} ns", .{s.max_ns}) else try allocator.dupe(u8, "-");
        defer allocator.free(mx);
        // FPS is only meaningful for latency scenarios, where `value` is the
        // mean frame ns; throughput scenarios already report a rate in `value`.
        const fps = if (s.unit == .latency_ns and s.value > 0)
            try std.fmt.allocPrint(allocator, "{d:.1}", .{1_000_000_000.0 / s.value})
        else
            try allocator.dupe(u8, "-");
        defer allocator.free(fps);
        try w.print("| {s} | {s} | {d:.2} | {s} | {s} | {s} | {s} | {d} | {d} |\n", .{
            s.name, s.unit.name(), s.value, fps, p50, p95, mx, s.samples, s.duration_ms,
        });
    }

    return buf.toOwnedSlice(allocator);
}

fn writeJsonField(w: anytype, key: []const u8, value: []const u8) !void {
    try w.print("\"{s}\":", .{key});
    try writeJsonString(w, value);
}

fn writeJsonString(w: anytype, s: []const u8) !void {
    try w.writeAll("\"");
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0...8, 11, 12, 14...31 => try w.print("\\u{x:0>4}", .{c}),
            else => try w.writeByte(c),
        }
    }
    try w.writeAll("\"");
}

test "report: JSON includes shared scalars and omits null gpu/window" {
    const allocator = std.testing.allocator;
    const scenarios = [_]ScenarioResult{
        .{ .name = "terminal-stream", .unit = .throughput, .value = 56.2, .samples = 900, .duration_ms = 1000 },
    };
    const r: Report = .{
        .app_version = "1.31.0",
        .os = "windows",
        .cpu_arch = "x86_64",
        .logical_cores = 8,
        .runner = "cli",
        .backend = "opengl",
        .scenarios = &scenarios,
        .timestamp_ms = 1234,
    };
    const json = try formatJson(allocator, r);
    defer allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"app_version\":\"1.31.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"logical_cores\":8") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"backend\":\"opengl\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"runner\":\"cli\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"value\":56.2") != null);
    // No gpu/window keys when null.
    try std.testing.expect(std.mem.indexOf(u8, json, "\"gpu\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"window\"") == null);
}

test "report: JSON includes gpu/window when filled and latency percentiles" {
    const allocator = std.testing.allocator;
    const scenarios = [_]ScenarioResult{
        .{ .name = "scroll_flood", .unit = .latency_ns, .value = 1_000_000, .p50_ns = 900_000, .p95_ns = 1_800_000, .max_ns = 3_000_000, .samples = 600, .duration_ms = 10_000 },
    };
    const r: Report = .{
        .app_version = "1.31.0",
        .os = "macos",
        .cpu_arch = "aarch64",
        .logical_cores = 10,
        .runner = "in-app",
        .backend = "metal",
        .gpu = .{ .backend = "metal", .adapter = "Apple M2", .vendor_id = 0, .device_id = 0 },
        .window = .{ .width_px = 1280, .height_px = 800, .grid_cols = 120, .grid_rows = 40, .dpi = 144 },
        .scenarios = &scenarios,
    };
    const json = try formatJson(allocator, r);
    defer allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"gpu\":{\"backend\":\"metal\",\"adapter\":\"Apple M2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"window\":{\"width_px\":1280") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"p50_ns\":900000") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"unit\":\"latency_ns\"") != null);
}

test "report: Markdown renders header, env, and scenario table" {
    const allocator = std.testing.allocator;
    const scenarios = [_]ScenarioResult{
        .{ .name = "terminal-stream", .unit = .throughput, .value = 56.2, .samples = 900, .duration_ms = 1000 },
        .{ .name = "scroll_flood", .unit = .latency_ns, .value = 1_000_000, .p50_ns = 900_000, .p95_ns = 1_800_000, .max_ns = 3_000_000, .samples = 600, .duration_ms = 10_000 },
    };
    const r: Report = .{
        .app_version = "1.31.0",
        .os = "windows",
        .cpu_arch = "x86_64",
        .logical_cores = 8,
        .runner = "cli",
        .backend = "d3d11",
        .scenarios = &scenarios,
    };
    const md = try formatMarkdown(allocator, r);
    defer allocator.free(md);
    try std.testing.expect(std.mem.indexOf(u8, md, "## WispTerm performance report") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "**backend:** d3d11") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "terminal-stream") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "scroll_flood") != null);
    try std.testing.expect(std.mem.indexOf(u8, md, "900000 ns") != null);
}

test "report: JSON escapes quotes/backslashes in string fields" {
    const allocator = std.testing.allocator;
    const r: Report = .{
        .app_version = "1.0",
        .os = "win\"dows\\x",
        .cpu_arch = "x86_64",
        .logical_cores = 1,
        .runner = "cli",
        .backend = "opengl",
    };
    const json = try formatJson(allocator, r);
    defer allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"os\":\"win\\\"dows\\\\x\"") != null);
}
