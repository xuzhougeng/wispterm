//! In-app GPU render benchmark driver (`wispterm --benchmark`).
//!
//! Owns all benchmark run state in this module — AppWindow only queries
//! `isEnabled()` and calls `start` / `frameBegin` / `frameEnd` / `finished` /
//! `finishAndWriteReport` at the main-loop hooks. No `g_*` state is added to
//! AppWindow/input/overlays (the integration-layer ratchets stay put).
//!
//! Measurement model: vsync off, the main loop spins on a dirty surface, and
//! each frame's CPU pipeline time (render-gate entry → present return) is
//! recorded as a latency sample. The UI thread direct-feeds a synthetic VT
//! payload to the active surface every frame (no PTY/shell), so the feed cost
//! lands outside the measured window and the two renderer backends are
//! compared on pure rebuild+draw+present work.

const std = @import("std");
const Surface = @import("../Surface.zig");
const Pty = @import("../platform/pty.zig").Pty;
const scenarios = @import("scenarios.zig");
const stats = @import("stats.zig");
const report = @import("report.zig");
const env = @import("env.zig");
const report_io = @import("report_io.zig");

/// Set by `main.zig` when `--benchmark` is present on the command line.
pub var enabled: bool = false;

pub fn isEnabled() bool {
    return enabled;
}

const State = struct {
    allocator: std.mem.Allocator,
    surface: *Surface,
    schedule: scenarios.Schedule,
    /// Frame pipeline samples (ns) for the scenario currently being measured.
    current_samples: std.ArrayList(i64) = .empty,
    /// Completed scenario results, in run order.
    results: std.ArrayList(report.ScenarioResult) = .empty,
    /// One generated payload per scenario (indexed by `schedule.idx`).
    payloads: [][]u8,
    /// The virtual PTY controller half of the benchmark surface. Held for the
    /// whole run so the surface's read thread never sees EOF; the driver
    /// direct-feeds the terminal, so this is lifecycle-only.
    controller: Pty.VirtualController,
    /// Nano-timestamp captured at the render-gate entry of the current frame.
    frame_start_ns: i64 = 0,
    report_written: bool = false,

    fn deinit(self: *State) void {
        for (self.results.items) |r| self.allocator.free(r.name);
        self.results.deinit(self.allocator);
        self.current_samples.deinit(self.allocator);
        for (self.payloads) |p| self.allocator.free(p);
        self.allocator.free(self.payloads);
        self.controller.deinit();
    }
};

var g_state: ?State = null;

/// Begin a benchmark run against `surface` (a virtual, no-shell surface).
/// `controller` is the write half of the surface's virtual PTY; the driver
/// keeps it open for the run and direct-feeds the terminal itself. Feeds the
/// first scenario's payload so the very first rendered frame has content.
pub fn start(
    allocator: std.mem.Allocator,
    surface: *Surface,
    cols: usize,
    controller: Pty.VirtualController,
) !void {
    if (g_state != null) return;
    const cfg: scenarios.ScenarioConfig = .{};
    const payloads = try allocator.alloc([]u8, scenarios.all_scenarios.len);
    errdefer allocator.free(payloads);
    var generated: usize = 0;
    errdefer {
        for (payloads[0..generated]) |p| allocator.free(p);
    }
    for (scenarios.all_scenarios, 0..) |scen, i| {
        payloads[i] = try scenarios.generateScenarioPayload(allocator, scen, cols, cfg.payload_bytes);
        generated += 1;
    }

    g_state = .{
        .allocator = allocator,
        .surface = surface,
        .schedule = scenarios.Schedule.init(cfg),
        .payloads = payloads,
        .controller = controller,
    };
    errdefer g_state = null;

    // Prime the surface with the first scenario's payload; markOutputDirty so
    // the render gate fires on the next iteration instead of idling.
    try feedCurrent(&g_state.?);
    _ = surface.markOutputDirty();
}

/// Capture the render-gate entry timestamp for the current frame.
pub fn frameBegin() void {
    if (g_state) |*s| {
        s.frame_start_ns = @as(i64, @intCast(std.time.nanoTimestamp()));
    }
}

/// Record the frame that just presented, then feed the next chunk so the
/// upcoming frame has fresh content. Drives warmup → measure → scenario
/// transitions via the schedule. Errors propagate (e.g. OOM appending a
/// sample); the caller should abort the run on error.
pub fn frameEnd() !void {
    const s = &(g_state orelse return);
    const now_ns: i64 = @as(i64, @intCast(std.time.nanoTimestamp()));
    const frame_ns = now_ns - s.frame_start_ns;
    const now_ms: i64 = @divTrunc(now_ns, std.time.ns_per_ms);

    if (s.schedule.observeFrame(now_ms)) {
        try s.current_samples.append(s.allocator, frame_ns);
    }
    if (s.schedule.shouldFinishScenario(now_ms)) {
        try finishCurrentScenario(s);
    }
    if (!s.schedule.done) {
        try feedCurrent(s);
        _ = s.surface.markOutputDirty();
    }
}

pub fn finished() bool {
    const s = g_state orelse return false;
    return s.schedule.done;
}

/// Assemble the full report (env + GPU/window info the caller supplies) and
/// write JSON + Markdown to the config dir, printing the Markdown to stdout.
/// `backend` is the resolved renderer backend (e.g. "opengl"/"d3d11") — the
/// caller knows `gpu.active`, while `env.backend` is only the build option
/// ("auto" for the app). Safe to call once; idempotent.
pub fn finishAndWriteReport(
    backend: []const u8,
    gpu: ?report.GpuInfo,
    window: ?report.WindowInfo,
) !void {
    const s = &(g_state orelse return);
    if (s.report_written) return;
    const e = env.collect();
    const rep: report.Report = .{
        .app_version = e.app_version,
        .os = e.os,
        .cpu_arch = e.cpu_arch,
        .logical_cores = e.logical_cores,
        .runner = "in-app",
        .backend = backend,
        .gpu = gpu,
        .window = window,
        .scenarios = s.results.items,
        .timestamp_ms = std.time.milliTimestamp(),
    };

    const json = try report.formatJson(s.allocator, rep);
    defer s.allocator.free(json);
    const md = try report.formatMarkdown(s.allocator, rep);
    defer s.allocator.free(md);

    std.debug.print("wispterm-benchmark: {d} scenarios measured\n", .{s.results.items.len});
    try report_io.emitReport(s.allocator, json, md);
    s.report_written = true;
}

/// Tear down the run, freeing all driver-owned memory. Called by AppWindow on
/// close after `finishAndWriteReport`.
pub fn deinit() void {
    if (g_state) |*s| {
        s.deinit();
        g_state = null;
    }
    enabled = false;
}

/// Compute the latency summary for the scenario that just elapsed, store it as
/// a `ScenarioResult`, then advance the schedule and reset per-scenario samples.
fn finishCurrentScenario(s: *State) !void {
    const scen = s.schedule.currentScenario() orelse return;
    const samples = s.current_samples.items;
    const sort_buf = try s.allocator.alloc(i64, samples.len);
    defer s.allocator.free(sort_buf);
    const summary = stats.summaryWithBuf(samples, sort_buf);

    const mean_ns: f64 = if (summary.count > 0)
        @as(f64, @floatFromInt(summary.mean))
    else
        0;

    try s.results.append(s.allocator, .{
        .name = try s.allocator.dupe(u8, scen.name()),
        .unit = .latency_ns,
        .value = mean_ns,
        .p50_ns = summary.p50,
        .p95_ns = summary.p95,
        .max_ns = summary.max,
        .samples = summary.count,
        .duration_ms = s.schedule.cfg.duration_ms,
    });
    s.current_samples.clearRetainingCapacity();
    s.schedule.advance();
}

/// Feed the current scenario's pre-generated payload to the surface under the
/// render-state mutex, matching the IO thread's locking discipline so the VT
/// parser and screen state stay consistent.
fn feedCurrent(s: *State) !void {
    const idx = s.schedule.idx;
    if (idx >= s.payloads.len) return;
    const data = s.payloads[idx];
    s.surface.render_state.mutex.lock();
    defer s.surface.render_state.mutex.unlock();
    s.surface.feedVtWithWispTermImageFallback(data);
}

test "driver: start/frameEnd/finishAndWriteReport round-trip with a stub surface is not linked here" {
    // The driver links Surface + platform_dirs (app-side), so its integration
    // tests live in test-full. This stub test only forces analysis of the
    // module's public API surface so a signature drift is caught at compile.
    _ = &start;
    _ = &frameBegin;
    _ = &frameEnd;
    _ = &finished;
    _ = &finishAndWriteReport;
    _ = &deinit;
    _ = isEnabled;
    try std.testing.expect(!isEnabled());
}
