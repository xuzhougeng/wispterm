const std = @import("std");
const builtin = @import("builtin");

pub const Backend = enum {
    windows,
    unsupported,
};

pub fn backendForOs(os_tag: std.Target.Os.Tag) Backend {
    return switch (os_tag) {
        .windows => .windows,
        else => .unsupported,
    };
}

const impl = switch (backendForOs(builtin.os.tag)) {
    .windows => @import("memory_windows.zig"),
    .unsupported => @import("memory_unsupported.zig"),
};

pub const ProcessSnapshot = struct {
    working_set: usize,
    peak_working_set: usize,
    pagefile_usage: usize,
    peak_pagefile_usage: usize,
    private_usage: usize,
    page_fault_count: u32,
};

pub fn queryProcess() ?ProcessSnapshot {
    return impl.queryProcess(ProcessSnapshot);
}

pub fn mib(bytes: usize) f64 {
    return @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0);
}

test "platform memory exposes process snapshot sampling API" {
    const snapshot = ProcessSnapshot{
        .working_set = 1,
        .peak_working_set = 2,
        .pagefile_usage = 3,
        .peak_pagefile_usage = 4,
        .private_usage = 5,
        .page_fault_count = 6,
    };

    try std.testing.expectEqual(@as(usize, 1), snapshot.working_set);
    try std.testing.expectEqual(@as(f64, 1.0), mib(1024 * 1024));
    try std.testing.expectEqual(@as(usize, 0), @typeInfo(@TypeOf(queryProcess)).@"fn".params.len);
}

test "platform memory selects backend by target OS" {
    try std.testing.expectEqual(Backend.windows, backendForOs(.windows));
    try std.testing.expectEqual(Backend.unsupported, backendForOs(.linux));
    try std.testing.expectEqual(Backend.unsupported, backendForOs(.macos));
}
