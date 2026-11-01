//! Aggregated render-pipeline timing for opt-in diagnostics.
//!
//! The state is thread-local because the window render loop and the D3D11
//! presenter are driven by one thread. Keeping the aggregation here avoids
//! adding another mutable field to AppWindow while still making the expensive
//! phases independently measurable.

const std = @import("std");
const render_diagnostics = @import("../render_diagnostics.zig");

pub const Stage = enum {
    frame_gate_wait,
    atlas_sync,
    snapshot,
    rebuild,
    draw,
    present_block,
};

pub const Sample = struct {
    frame_gate_wait_ns: u64 = 0,
    atlas_sync_ns: u64 = 0,
    snapshot_ns: u64 = 0,
    rebuild_ns: u64 = 0,
    draw_ns: u64 = 0,
    present_block_ns: u64 = 0,
};

pub const Aggregate = struct {
    frames: u64 = 0,
    frame_gate_wait_ns: u64 = 0,
    atlas_sync_ns: u64 = 0,
    snapshot_ns: u64 = 0,
    rebuild_ns: u64 = 0,
    draw_ns: u64 = 0,
    present_block_ns: u64 = 0,
    max_present_block_ns: u64 = 0,

    pub fn add(self: *Aggregate, sample: Sample) void {
        self.frames += 1;
        self.frame_gate_wait_ns += sample.frame_gate_wait_ns;
        self.atlas_sync_ns += sample.atlas_sync_ns;
        self.snapshot_ns += sample.snapshot_ns;
        self.rebuild_ns += sample.rebuild_ns;
        self.draw_ns += sample.draw_ns;
        self.present_block_ns += sample.present_block_ns;
        self.max_present_block_ns = @max(self.max_present_block_ns, sample.present_block_ns);
    }

    pub fn reset(self: *Aggregate) void {
        self.* = .{};
    }

    pub fn average(total_ns: u64, frames: u64) u64 {
        return if (frames == 0) 0 else total_ns / frames;
    }
};

threadlocal var g_current: ?Sample = null;
threadlocal var g_aggregate: Aggregate = .{};
threadlocal var g_last_report_ms: i64 = 0;

pub fn beginFrame() void {
    g_current = if (render_diagnostics.enabled()) Sample{} else null;
}

pub fn beginStage() i128 {
    return if (g_current != null) std.time.nanoTimestamp() else 0;
}

pub fn endStage(stage: Stage, started_ns: i128) void {
    if (started_ns == 0) return;
    const elapsed = std.time.nanoTimestamp() - started_ns;
    const elapsed_ns: u64 = if (elapsed > 0) @intCast(elapsed) else 0;
    const sample = if (g_current) |*value| value else return;
    switch (stage) {
        .frame_gate_wait => sample.frame_gate_wait_ns += elapsed_ns,
        .atlas_sync => sample.atlas_sync_ns += elapsed_ns,
        .snapshot => sample.snapshot_ns += elapsed_ns,
        .rebuild => sample.rebuild_ns += elapsed_ns,
        .draw => sample.draw_ns += elapsed_ns,
        .present_block => sample.present_block_ns += elapsed_ns,
    }
}

pub fn abortFrame() void {
    g_current = null;
}

pub fn finishFrame() void {
    const sample = g_current orelse return;
    g_current = null;
    g_aggregate.add(sample);

    const now_ms = std.time.milliTimestamp();
    if (g_last_report_ms == 0) g_last_report_ms = now_ms;
    if (now_ms - g_last_report_ms < 1000) return;

    const frames = g_aggregate.frames;
    render_diagnostics.log(
        "frame-timing frames={} avg_gate_us={} avg_atlas_us={} avg_snapshot_us={} avg_rebuild_us={} avg_draw_us={} avg_present_block_us={} max_present_block_us={}",
        .{
            frames,
            nsToUs(Aggregate.average(g_aggregate.frame_gate_wait_ns, frames)),
            nsToUs(Aggregate.average(g_aggregate.atlas_sync_ns, frames)),
            nsToUs(Aggregate.average(g_aggregate.snapshot_ns, frames)),
            nsToUs(Aggregate.average(g_aggregate.rebuild_ns, frames)),
            nsToUs(Aggregate.average(g_aggregate.draw_ns, frames)),
            nsToUs(Aggregate.average(g_aggregate.present_block_ns, frames)),
            nsToUs(g_aggregate.max_present_block_ns),
        },
    );
    g_aggregate.reset();
    g_last_report_ms = now_ms;
}

fn nsToUs(value: u64) u64 {
    return value / 1000;
}

test "frame timing aggregates all render phases" {
    var aggregate: Aggregate = .{};
    aggregate.add(.{
        .frame_gate_wait_ns = 10,
        .atlas_sync_ns = 20,
        .snapshot_ns = 30,
        .rebuild_ns = 40,
        .draw_ns = 50,
        .present_block_ns = 60,
    });
    aggregate.add(.{ .present_block_ns = 100 });

    try std.testing.expectEqual(@as(u64, 2), aggregate.frames);
    try std.testing.expectEqual(@as(u64, 5), Aggregate.average(aggregate.frame_gate_wait_ns, aggregate.frames));
    try std.testing.expectEqual(@as(u64, 80), Aggregate.average(aggregate.present_block_ns, aggregate.frames));
    try std.testing.expectEqual(@as(u64, 100), aggregate.max_present_block_ns);
}
