//! Benchmark environment collection: the cross-platform scalars shared by
//! every report (app version, OS, CPU arch, logical cores, renderer backend).
//! GPU-adapter / window / DPI fields are filled by the in-app runner (future
//! M2) directly into `report.Report`; this module only gathers what the
//! `wispterm-bench` CLI can know without a window.
//!
//! Depends on `build_options` (app_version, gpu_backend), so it is compiled
//! into the bench binary and the in-app benchmark, not the fast suite.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

pub const Env = struct {
    app_version: []const u8,
    os: []const u8,
    cpu_arch: []const u8,
    logical_cores: u32,
    /// Renderer backend the report is about ("opengl" | "metal" | "d3d11"), or
    /// "n/a" for the CPU-only CLI which links no GPU backend.
    backend: []const u8,
};

pub fn collect() Env {
    const cores = std.Thread.getCpuCount() catch 1;
    return .{
        .app_version = build_options.app_version,
        .os = @tagName(builtin.os.tag),
        .cpu_arch = @tagName(builtin.cpu.arch),
        .logical_cores = @intCast(cores),
        .backend = build_options.gpu_backend,
    };
}
