//! Process memory sampling for debug builds/runs.

const platform_memory = @import("platform/memory.zig");

pub const ProcessSnapshot = platform_memory.ProcessSnapshot;
pub const queryProcess = platform_memory.queryProcess;
pub const mib = platform_memory.mib;

test "memory debug delegates process sampling to platform memory" {
    const snapshot = ProcessSnapshot{
        .working_set = 1,
        .peak_working_set = 2,
        .pagefile_usage = 3,
        .peak_pagefile_usage = 4,
        .private_usage = 5,
        .page_fault_count = 6,
    };

    try @import("std").testing.expectEqual(@as(usize, 5), snapshot.private_usage);
    try @import("std").testing.expectEqual(@as(f64, 2.0), mib(2 * 1024 * 1024));
}
